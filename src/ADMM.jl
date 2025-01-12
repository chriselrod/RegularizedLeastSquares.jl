export admm

mutable struct ADMM{matT,opT,vecT,rvecT,preconT} <: AbstractLinearSolver
  # oerators and regularization
  A::matT
  reg::Vector{Regularization}
  # fields and operators for x update
  op::opT
  β::vecT
  β_y::vecT
  # fields for primal & dual variables
  x::vecT
  z::Vector{vecT}
  zᵒˡᵈ::Vector{vecT}
  u::Vector{vecT}
  # other parameters
  precon::preconT
  ρ::rvecT
  iterations::Int64
  iterationsInner::Int64
  # state variables for CG
  cgStateVars::CGStateVariables
  # convergence parameters
  rᵏ::rvecT
  sᵏ::vecT
  ɛᵖʳⁱ::rvecT
  ɛ_dt::vecT
  σᵃᵇˢ::Float64
  absTol::Float64
  relTol::Float64
  tolInner::Float64
  normalizeReg::Bool
  regFac::Float64
end

"""
    ADMM(A, x::vecT=zeros(eltype(A),size(A,2))
          ; reg=nothing, regName=["L1"], λ=[0.0], kargs...)

creates an `ADMM` object for the system matrix `A`.

# Arguments
* `A`                           - system matrix
* `x::vecT`                     - Array with the same type and size as the solution
* (`reg=nothing`)               - Regularization object
* (`regName=["L1"]`)            - name of the Regularization to use (if reg==nothing)
* (`λ=[0.0]`)                   - Regularization paramter
* (`precon=Identity()`)         - preconditionner for the internal CG algorithm
* (`ρ::Float64=1.e-2`)          - penalty of the augmented lagrangian
* (`adaptRho::Bool=false`)      - adapt rho to balance primal and dual feasibility
* (`iterations::Int64=50`)      - max number of ADMM iterations
* (`iterationsInner::Int64=10`) - max number of internal CG iterations
* (`absTol::Float64=eps()`)     - abs tolerance for stopping criterion
* (`relTol::Float64=eps()`)     - rel tolerance for stopping criterion
* (`tolInner::Float64=1.e-5`)   - tolerance for CG stopping criterion
"""
function ADMM(A::matT, x::vecT=zeros(eltype(A),size(A,2)); reg=nothing, regName=["L1"]
            , λ=[0.0]
            , AHA::opT=nothing
            , precon=Identity()
            , ρ=[1.e-1]
            , iterations::Int64=50
            , iterationsInner::Int64=10
            , absTol::Float64=eps()
            , relTol::Float64=eps()
            , tolInner::Float64=1.e-5
            , normalizeReg::Bool=false
            , kargs...) where {matT,vecT,opT}

  if reg == nothing
    reg = Regularization(regName, λ, kargs...)
  end

  # fields for primal & dual variables
  z = [similar(x) for i=1:length(vec(reg))]
  zᵒˡᵈ = [similar(x) for i=1:length(vec(reg))]
  u = [similar(x) for i=1:length(vec(reg))]

  # operator and fields for the update of x
  if AHA != nothing
    op = AHA + sum(ρ)*opEye(size(A,2))
  else
    op = A'*A + sum(ρ)*opEye(size(A,2))
  end
  β = similar(x)
  β_y = similar(x)

  # statevariables for CG
  # we store them here to prevent CG from allocating new fields at each call
  statevars = CGStateVariables(zero(x),similar(x),similar(x))

  # convergence parameters
  rk = similar( real.(x), length(vec(reg)) ) #[0.0 for i=1:length(vec(reg))]
  sk = similar(x)
  eps_pri = similar( real.(x), length(vec(reg)) ) # [0.0 for i=1:length(vec(reg))]
  eps_dt = similar(x)

  # make sure that ρ is a vector and of proper type
  if typeof(ρ) <: Real
    ρ_vec = similar(x, real(eltype(x)), 1)
    ρ_vec .= ρ
  else
    ρ_vec = typeof(real.(x))(ρ)
  end

  return ADMM(A,vec(reg),op,β,β_y,x,z,zᵒˡᵈ,u,precon,ρ_vec,iterations
              ,iterationsInner,statevars, rk,sk,eps_pri,eps_dt,0.0,absTol,relTol,tolInner
              ,normalizeReg,1.0)
end

"""
  init!(solver::ADMM{matT,opT,vecT,rvecT,preconT}, b::vecT
              ; A::matT=solver.A
              , AHA::opT=solver.op
              , x::vecT=similar(b,0)
              , kargs...) where {matT,opT,vecT,rvecT,preconT}

(re-) initializes the ADMM iterator
"""
function init!(solver::ADMM{matT,opT,vecT,rvecT,preconT}, b::vecT
              ; A::matT=solver.A
              , AHA::opT=solver.op
              , x::vecT=similar(b,0)
              , kargs...) where {matT,opT,vecT,rvecT,preconT}

  # operators
  if A != solver.A
    solver.A = A
    if AHA != nothing
      solver.op = AHA + sum(solver.ρ)*opEye(length(solver.x))
    else
      solver.op = A'*A + sum(solver.ρ)*opEye(length(solver.x))
    end
  end

  # start vector
  if isempty(x)
    if !isempty(b)
      solver.x .= adjoint(A) * b
    else
      solver.x .= 0.0
    end
  else
    solver.x[:] .= x
  end

  # primal and dual variables
  for i=1:length(solver.reg)
    solver.z[i][:] .= solver.x
    solver.zᵒˡᵈ[i][:] .= 0.0
    solver.u[i] .= 0.0
  end

  # right hand side for the x-update
  solver.β_y[:] .= adjoint(A) * b

  # convergence parameter
  solver.rᵏ .= 0
  solver.sᵏ .= 0 
  solver.ɛᵖʳⁱ .= 0
  solver.ɛ_dt .= 0
  solver.σᵃᵇˢ = sqrt(length(b))*solver.absTol

  # normalization of regularization parameters
  if solver.normalizeReg
    solver.regFac = norm(b,1)/length(b)
  else
    solver.regFac = 1.0
  end
end

"""
    solve(solver::ADMM, b::vecT
          ; A::matT=solver.A
          , startVector::vecT=similar(b,0)
          , solverInfo=nothing
          , kargs...) where {matT,vecT}

solves an inverse problem using ADMM.

# Arguments
* `solver::ADMM`                  - the solver containing both system matrix and regularizer
* `b::Vector`                     - data vector
* (`A::matT=solver.A`)            - operator for the data-term of the problem
* (`startVector::Vector{T}=T[]`)  - initial guess for the solution
* (`solverInfo=nothing`)          - solverInfo for logging

when a `SolverInfo` objects is passed, the primal residuals `solver.rk`
and the dual residual `norm(solver.sk)` are stored in `solverInfo.convMeas`.
"""
function solve(solver::ADMM, b::vecT; A::matT=solver.A, startVector::vecT=similar(b,0), solverInfo=nothing, kargs...) where {matT,vecT}
  # initialize solver parameters
  init!(solver, b; A=A, x=startVector)

  # log solver information
  solverInfo != nothing && storeInfo(solverInfo,solver.z,solver.rk...,norm(solver.sk))

  # perform ADMM iterations
  for (iteration, item) = enumerate(solver)
    solverInfo != nothing && storeInfo(solverInfo,solver.z,solver.rk...,norm(solver.sk))
  end

  return solver.x
end

"""
  iterate(it::ADMM, iteration::Int=0)

performs one ADMM iteration.
"""
function iterate(solver::ADMM{matT,opT,T,preconT}, iteration::Int=0) where {matT,opT,T,preconT}
  if done(solver, iteration) return nothing end

  # 1. solve arg min_x 1/2|| Ax-b ||² + ρ/2 ||x+u-z||²
  # <=> (A'A+ρ)*x = A'b+ρ(z-u)
  copyto!(solver.β, solver.β_y)
  for i=1:length(solver.reg)
    solver.β[:] .+= solver.ρ[i]*(solver.z[i].-solver.u[i])
  end
  cg!(solver.x, solver.op, solver.β, Pl=solver.precon
      , maxiter=solver.iterationsInner, tol=solver.tolInner, statevars=solver.cgStateVars)

  # 2. update z using the proximal map of 1/ρ*g(x)
  for i=1:length(solver.reg)
    copyto!(solver.zᵒˡᵈ[i], solver.z[i])
    solver.z[i][:] .= solver.x .+ solver.u[i]
    if solver.ρ[i] != 0
      solver.reg[i].prox!(solver.z[i], solver.regFac*solver.reg[i].λ/solver.ρ[i]; solver.reg[i].params...)
    end
  end

  # 3. update u
  for i=1:length(solver.reg)
    solver.u[i][:] .+= solver.x .- solver.z[i]
  end

  # update convergence measures
  for i=1:length(solver.reg)
    solver.rᵏ[i] = norm(solver.x-solver.z[i])  # primal residual (x-z)
    solver.ɛᵖʳⁱ[i] = solver.σᵃᵇˢ + solver.relTol*max( norm(solver.x), norm(solver.z[i]) )
  end
  solver.sᵏ[:] .= 0.0
  solver.ɛ_dt[:] .= 0.0
  for i=1:length(solver.reg)
    solver.sᵏ[:] .+= norm(solver.ρ[i] * (solver.z[i] .- solver.zᵒˡᵈ[i])) # dual residual (concerning f(x))
    solver.ɛ_dt[:] .+= solver.ρ[i]*solver.u[i]
  end

  # return the primal feasibilty measure as item and iteration number as state
  return solver.rᵏ, iteration+1
end

function converged(solver::ADMM)
  if norm(solver.sᵏ) >= solver.σᵃᵇˢ+solver.relTol*norm(solver.ɛ_dt)
    return false
  else
    for i=1:length(solver.reg)
      (solver.rᵏ[i] >= solver.ɛᵖʳⁱ[i]) && return false
    end
  end

  return true
end

@inline done(solver::ADMM,iteration::Int) = converged(solver) || iteration>=solver.iterations
