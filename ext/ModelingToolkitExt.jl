module ModelingToolkitExt

using ModelingToolkit: Symbolic, iscall, operation, arguments, build_function
using ModelingToolkit: ModelingToolkit, Equation, ODESystem, Differential
using ModelingToolkit: full_equations, get_variables, structural_simplify, getname, unwrap
using ModelingToolkit: full_parameters, unknowns, independent_variables, observed, defaults
using ModelingToolkit: get_substitutions
using ModelingToolkit.Symbolics: Symbolics, fixpoint_sub
using ArgCheck: @argcheck
using LinearAlgebra: Diagonal, I

using NetworkDynamics: Fiducial
import NetworkDynamics: ODEVertex, StaticEdge

include("ModelingToolkitUtils.jl")

function ODEVertex(sys::ODESystem, inputs, outputs; verbose=false)
    warn_events(sys)
    inputs = inputs isa AbstractVector ? inputs : [inputs]
    outputs = outputs isa AbstractVector ? outputs : [outputs]
    gen = generate_io_function(sys, (inputs, ), outputs; type=:ode, verbose)

    f = gen.f_ip
    defdict = _resolved_defaults(sys)
    sym = getname.(gen.states)
    def = map(gen.states) do s
        get(defdict, s, nothing)
    end
    psym = getname.(gen.params)
    pdef = map(gen.params) do p
        get(defdict, p, nothing)
    end
    depth = length(outputs)
    obsf = gen.g_ip
    obssym = getname.(gen.obsstates)
    mass_matrix = gen.mass_matrix
    name = getname(sys)
    ODEVertex(;f, sym, def, psym, pdef, depth, obssym, obsf, mass_matrix, name)
end

function StaticEdge(sys::ODESystem, srcin, dstin, outputs, coupling; verbose=false)
    warn_events(sys)
    srcin = srcin isa AbstractVector ? srcin : [srcin]
    dstin = dstin isa AbstractVector ? dstin : [dstin]
    outputs = outputs isa AbstractVector ? outputs : [outputs]
    gen = generate_io_function(sys, (srcin, dstin), outputs; type=:static, verbose)

    f = gen.f_ip
    defdict = _resolved_defaults(sys)
    sym = getname.(gen.states)
    def = map(gen.states) do s
        get(defdict, s, nothing)
    end
    psym = getname.(gen.params)
    pdef = map(gen.params) do p
        get(defdict, p, nothing)
    end
    obsf = gen.g_ip
    obssym = getname.(gen.obsstates)
    depth = coupling isa Fiducial ? Int(length(outputs)/2) : length(outputs)
    name = getname(sys)
    StaticEdge(;f, sym, def, psym, pdef, depth, obssym, obsf, coupling, name)
end

"""
defaults might be given als algebraic map from other parameters, try to resolve
"""
function _resolved_defaults(sys)
    _defdict = defaults(sys)
    defdict = Dict()
    for (k,v) in _defdict
       if v isa Symbolic
          v = fixpoint_sub(v, _defdict)
          if v isa Symbolic
             error("Could not resolve $k => $v in defaults map!")
          end
       end
       defdict[k] = v
    end
    defdict
end

function generate_io_function(_sys, inputss::Tuple, outputs;
                              expression=Val{false}, verbose=false, type=:auto)
    # TODO: scalarize vector symbolics/equations?

    # f_* may be given in namepsace version or as symbols, resolve to unnamespaced Symbolic
    inputss = map(inputss) do in
        _resolve_to_symbolic.(Ref(_sys), in)
    end
    allinputs = reduce(union, inputss)
    outputs = _resolve_to_symbolic.(Ref(_sys), outputs)

    sys = if ModelingToolkit.iscomplete(_sys)
        _sys
    else
        _openinputs = setdiff(allinputs, Set(full_parameters(_sys)))
        structural_simplify(_sys, (_openinputs, outputs); simplify=true)[1]
    end

    # extract "temporary" states and params, those might change in the following steps
    _states = unknowns(sys)
    _params = full_parameters(sys)

    # extract the main equations and observed equations
    eqs::Vector{Equation} = full_equations(sys)
    fix_metadata!(eqs, sys);

    # extract observed equations. They might depend on eachother so resolve them
    obs_subs = Dict(eq.lhs => eq.rhs for eq in observed(sys))
    obseqs = map(observed(sys)) do eq
        eq.lhs ~ fixpoint_sub(eq.rhs, obs_subs)
    end
    fix_metadata!(obseqs, sys);
    # obs can only depend on parameters (including allinputs) or states
    obs_deps = mapreduce(eq -> get_variables(eq.rhs), union, obseqs, init=Symbolic[])
    if !(obs_deps ⊆ Set(_params) ∪ Set(_states))
        @warn "obs_deps !⊆ parameters ∪ unknowns. Difference: $(setdiff(obs_deps, Set(_params) ∪ Set(_states)))"
    end

    @argcheck allinputs ⊆ Set(_params)

    if !(outputs ⊆ Set(_states))
        # structural simplify might remove explicit equations for outputs
        # so we reconstruct equations for them based on the substitutions
        missingouts = setdiff(Set(outputs), _states)
        subs = Dict(eq.lhs => eq.rhs for eq in obseqs)
        @argcheck missingouts ⊆ keys(subs)

        renamings = Dict()
        for mout in missingouts
            eq = mout ~ fixpoint_sub(mout, subs)

            # try the ol' switcheroo for trivial equations a ~ b
            if iscall(eq.rhs) && operation(eq.rhs) isa Symbolics.BasicSymbolic && eq.rhs ∈ Set(_states)
                verbose && @info "Encountered trivial equation $eq. Swap out $(eq.lhs) <=> $(eq.rhs) everywhere."
                renamings[eq.lhs] = eq.rhs
                renamings[eq.rhs] = eq.lhs
                continue
            end
            # chech for potentially other solvable scenarios
            rhs_vars = get_variables(eq.rhs)
            if length(rhs_vars) == 1 && (rhs_vars ⊆ Set(_states) || rhs_vars ⊆ Set(_params))
                @warn "Adding possible trivial equation $eq. This should be resolved in NetworkDynamics."
            end
            push!(eqs, eq)
        end
        fix_metadata!(eqs, sys);

        if !isempty(renamings)
            eqs = map(eq -> substitute(eq, renamings), eqs)
            obseqs = map(eq -> substitute(eq, renamings), obseqs)
            _states = map(s -> substitute(s, renamings), _states)
            verbose && @info "New States:" _states
        end

        # we promoted the missing outputs to "states" again, so we need to remove them from obseqs
        filter!(obseqs) do eq
            eq.lhs ∉ missingouts
        end
    end

    if !isempty(rhs_differentials(eqs))
        diffs = rhs_differentials(eqs)
        buf = IOBuffer()
        println(buf, "Equations contain differentials in their rhs: ", diffs)
        # for (i, eqs) in enumerate(eqs)
        #     if !isempty(rhs_differentials(eqs))
        #         println(buf, " - $i: $eqs")
        #     end
        # end
        throw(ArgumentError(String(take!(buf))))
    end

    # make sure that outputs appear first
    states = vcat(outputs, _states) |> unique
    params = setdiff(_params, Set(allinputs))

    # filter out unnecessary parameters
    used_params = params ∩ (mapreduce(get_variables, ∪, eqs, init=Set{Symbolic}()) ∪ mapreduce(get_variables, ∪, obseqs, init=Set{Symbolic}()))
    if Set(params) != Set(used_params)
        verbose && @info "Remove parameters $(collect(setdiff(params, used_params))) which arn't used in the equations."
        params = used_params
    end

    eqs = reorder_by_states(eqs, states)

    verbose && @info "Reordered eqs" eqs states

    if type == :auto
        all_static = all(isequal(:explicit_algebraic), first.(eq_type.(eqs)))
        type = all_static ? :static : :ode
        verbose && @info "auto-equation type: $type"
    end

    mass_matrix = if type == :ode
        # equations of form o = f(...) have to be transformed to 0 = f(...) - o
        for (i, eq) in enumerate(eqs)
           if eq_type(eq)[1] == :explicit_algebraic
               eqs[i] = 0 ~ eq.rhs - eq.lhs
           end
        end
        verbose && @info "Transformed algebraic eqs" eqs

        # create massmatrix, we don't use the method provided by ODESystem because of reordering
        mm = generate_massmatrix(eqs)
        verbose && @info "Reordered by states and generated mass matrix" mm
        mm
    elseif type == :static
        all_static = all(isequal(:explicit_algebraic), first.(eq_type.(eqs)))
        all_static || throw(ArgumentError("Equations of system are not static!"))
        nothing
    else
        throw(ArgumentError("Unknown type $type"))
    end

    # now generate the actual functions
    iv = independent_variables(sys)

    formulas = [eq.rhs for eq in eqs]
    if type == :ode
        f_oop, f_ip = build_function(formulas, states, inputss..., params, iv; expression)
    elseif type == :static
        f_oop, f_ip = build_function(formulas, inputss..., params, iv; expression)
    end

    # and the observed functions
    obsstates = [eq.lhs for eq in obseqs]
    obsformulas = [eq.rhs for eq in obseqs]
    g_oop, g_ip = build_function(obsformulas, states, inputss..., params, iv; expression)

    return (;f_oop, f_ip,
            mass_matrix,
            states,
            inputss,
            obsstates,
            g_oop, g_ip,
            params)
end

using PrecompileTools: @setup_workload, @compile_workload
@setup_workload begin
    @compile_workload begin
        include("precompile_workload.jl")
    end
end

end
