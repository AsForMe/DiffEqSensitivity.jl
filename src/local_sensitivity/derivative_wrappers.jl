# Not in FiniteDiff because `u` -> scalar isn't used anywhere else,
# but could be upstreamed.
mutable struct UGradientWrapper{fType,tType,P} <: Function
  f::fType
  t::tType
  p::P
end

(ff::UGradientWrapper)(uprev) = ff.f(uprev,ff.p,ff.t)

Base.@pure function determine_chunksize(u,alg::DiffEqBase.AbstractSensitivityAlgorithm)
  determine_chunksize(u,get_chunksize(alg))
end

Base.@pure function determine_chunksize(u,CS)
  if CS != 0
    return CS
  else
    return ForwardDiff.pickchunksize(length(u))
  end
end

function jacobian!(J::AbstractMatrix{<:Number}, f, x::AbstractArray{<:Number},
                   fx::AbstractArray{<:Number}, alg::DiffEqBase.AbstractSensitivityAlgorithm, jac_config)
  if alg_autodiff(alg)
    ForwardDiff.jacobian!(J, f, fx, x, jac_config)
  else
    FiniteDiff.finite_difference_jacobian!(J, f, x, jac_config)
  end
  nothing
end

function gradient!(df::AbstractArray{<:Number}, f,
                   x::Union{Number,AbstractArray{<:Number}},
                   alg::DiffEqBase.AbstractSensitivityAlgorithm, grad_config)
    if alg_autodiff(alg)
        ForwardDiff.gradient!(df, f, x, grad_config)
    else
        FiniteDiff.finite_difference_gradient!(df, f, x, grad_config)
    end
    nothing
end

"""
  jacobianvec!(Jv, f, x, v, alg, (buffer, seed)) -> nothing

``Jv <- J(f(x))v``
"""
function jacobianvec!(Jv::AbstractArray{<:Number}, f, x::AbstractArray{<:Number},
                      v, alg::DiffEqBase.AbstractSensitivityAlgorithm, config)
  if alg_autodiff(alg)
    buffer, seed = config
    TD = typeof(first(seed))
    T  = typeof(first(seed).partials)
    @. seed = TD(x, T(tuple(v)))
    f(buffer, seed)
    Jv .= ForwardDiff.partials.(buffer, 1)
  else
    buffer1, buffer2 = config
    f(buffer1,x)
    T = eltype(x)
    # Should it be min? max? mean?
    ϵ = sqrt(eps(real(T))) * max(one(real(T)), abs(norm(x)))
    @. x += ϵ*v
    f(buffer2,x)
    @. x -= ϵ*v
    @. du = (buffer2 - buffer1)/ϵ
  end
  nothing
end

function vecjacobian!(dλ, λ, p, t, S::SensitivityFunction;
                      dgrad=nothing, dy=nothing)
  _vecjacobian!(dλ, λ, p, t, S, S.sensealg.autojacvec, dgrad, dy)
  return
end

function _vecjacobian!(dλ, λ, p, t, S::SensitivityFunction, isautojacvec::Bool, dgrad, dy)
  @unpack y, sensealg = S
  prob = getprob(S)
  f = prob.f
  if isautojacvec isa Bool && !isautojacvec
    @unpack J, uf, f_cache, jac_config = S.diffcache
    if DiffEqBase.has_jac(f)
      f.jac(J,y,p,t) # Calculate the Jacobian into J
    else
      uf.t = t
      jacobian!(J, uf, y, f_cache, sensealg, jac_config)
    end
    mul!(dλ',λ',J)
    if dgrad !== nothing
      @unpack pJ, pf, paramjac_config = S.diffcache
      if DiffEqBase.has_paramjac(f)
        # Calculate the parameter Jacobian into pJ
        f.paramjac(pJ,y,prob.p,t)
      else
        jacobian!(pJ, pf, prob.p, f_cache, sensealg, paramjac_config)
      end
      mul!(dgrad',λ',pJ)
    end
    dy !== nothing && f(dy, y, p, t)
  elseif DiffEqBase.isinplace(prob)
    _vecjacobian!(dλ, λ, p, t, S, TrackerVJP(), dgrad, dy)
  else
    _vecjacobian!(dλ, λ, p, t, S, ZygoteVJP(), dgrad, dy)
  end
  return
end

function _vecjacobian!(dλ, λ, p, t, S::SensitivityFunction, isautojacvec::TrackerVJP, dgrad, dy)
  @unpack y, sensealg = S
  prob = getprob(S)
  f = prob.f
  isautojacvec = get_jacvec(sensealg)
  if DiffEqBase.isinplace(prob)
    _dy, back = Tracker.forward(y, prob.p) do u, p
      out_ = map(zero, u)
      f(out_, u, p, t)
      Tracker.collect(out_)
    end
    tmp1, tmp2 = Tracker.data.(back(λ))
    dλ[:] .= vec(tmp1)
    dgrad !== nothing && (dgrad[:] .= vec(tmp2))
    dy !== nothing && (dy[:] .= vec(Tracker.data(_dy)))
  else
    _dy, back = Tracker.forward(y, prob.p) do u, p
      Tracker.collect(f(u, p, t))
    end
    tmp1, tmp2 = Tracker.data.(back(λ))
    dλ[:] .= vec(tmp1)
    dgrad !== nothing && (dgrad[:] .= vec(tmp2))
    dy !== nothing && (dy[:] .= vec(Tracker.data(_dy)))
  end
  return
end

function _vecjacobian!(dλ, λ, p, t, S::SensitivityFunction, isautojacvec::ReverseDiffVJP, dgrad, dy)
  @unpack y, sensealg = S
  prob = getprob(S)
  f = prob.f
  isautojacvec = get_jacvec(sensealg)
  tape = S.diffcache.paramjac_config
  
  tu, tp = ReverseDiff.input_hook(tape)
  output = ReverseDiff.output_hook(tape)
  ReverseDiff.unseed!(tu) # clear any "leftover" derivatives from previous calls
  ReverseDiff.unseed!(tp)
  ReverseDiff.value!(tu, y)
  ReverseDiff.value!(tp, prob.p)
  ReverseDiff.forward_pass!(tape)
  ReverseDiff.increment_deriv!(output, λ)
  ReverseDiff.reverse_pass!(tape)
  copyto!(vec(dλ), ReverseDiff.deriv(tu))
  dgrad !== nothing && copyto!(vec(dgrad), ReverseDiff.deriv(tp))
  dy !== nothing && copyto!(vec(dy), ReverseDiff.value(output))
  return
end

function _vecjacobian!(dλ, λ, p, t, S::SensitivityFunction, isautojacvec::ZygoteVJP, dgrad, dy)
  @unpack y, sensealg = S
  prob = getprob(S)
  f = prob.f
  isautojacvec = get_jacvec(sensealg)
  if DiffEqBase.isinplace(prob)
    _dy, back = Zygote.pullback(y, prob.p) do u, p
      out_ = Zygote.Buffer(similar(u))
      f(out_, u, p, t)
      vec(copy(out_))
    end
    tmp1,tmp2 = back(λ)
    dλ[:] .= vec(tmp1)
    dgrad !== nothing && (dgrad[:] .= vec(tmp2))
    dy !== nothing && (dy[:] .= vec(_dy))
  else
    _dy, back = Zygote.pullback(y, prob.p) do u, p
      vec(f(u, p, t))
    end
    tmp1,tmp2 = back(λ)
    dλ[:] .= vec(tmp1)
    dgrad !== nothing && (dgrad[:] .= vec(tmp2))
    dy !== nothing && (dy[:] .= vec(_dy))
  end
  return
end

function accumulate_dgdu!(dλ, y, p, t, S::SensitivityFunction)
  @unpack dg, dg_val, g, g_grad_config = S.diffcache
  if dg != nothing
    dg(dg_val,y,p,t)
  else
    g.t = t
    gradient!(dg_val, g, y, S.sensealg, g_grad_config)
  end
  dλ .+= vec(dg_val)
  return nothing
end

function build_jac_config(alg,uf,u)
  if alg_autodiff(alg)
    jac_config = ForwardDiff.JacobianConfig(uf,u,u,
                 ForwardDiff.Chunk{determine_chunksize(u,alg)}())
  else
    if diff_type(alg) != Val{:complex}
      jac_config = FiniteDiff.JacobianCache(similar(u),similar(u),
                                                 similar(u),diff_type(alg))
    else
      tmp = Complex{eltype(u)}.(u)
      du1 = Complex{eltype(u)}.(du1)
      jac_config = FiniteDiff.JacobianCache(tmp,du1,nothing,diff_type(alg))
    end
  end
  jac_config
end

function build_param_jac_config(alg,uf,u,p)
  if alg_autodiff(alg)
    jac_config = ForwardDiff.JacobianConfig(uf,u,p,
                 ForwardDiff.Chunk{determine_chunksize(p,alg)}())
  else
    if diff_type(alg) != Val{:complex}
      jac_config = FiniteDiff.JacobianCache(similar(p),similar(u),
                                                 similar(u),diff_type(alg))
    else
      tmp = Complex{eltype(p)}.(p)
      du1 = Complex{eltype(u)}.(u)
      jac_config = FiniteDiff.JacobianCache(tmp,du1,nothing,diff_type(alg))
    end
  end
  jac_config
end

function build_grad_config(alg,tf,du1,t)
  if alg_autodiff(alg)
    grad_config = ForwardDiff.GradientConfig(tf,du1,
                                    ForwardDiff.Chunk{determine_chunksize(du1,alg)}())
  else
    grad_config = FiniteDiff.GradientCache(du1,t,diff_type(alg))
  end
  grad_config
end
