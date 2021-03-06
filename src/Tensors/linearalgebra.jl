export polar,
       eigenHermitian,
       Spectrum

#
# Linear Algebra of order 2 Tensors
#
# Even though DenseTensor{_,2} is strided
# and passable to BLAS/LAPACK, it cannot
# be made <: StridedArray
export eigs,
       truncerror,
       entropy

function Base.:*(T1::Tensor{ElT1,2,StoreT1,IndsT1},
                 T2::Tensor{ElT2,2,StoreT2,IndsT2}) where
                                       {ElT1,StoreT1<:Dense,IndsT1,
                                        ElT2,StoreT2<:Dense,IndsT2}
  RM = matrix(T1)*matrix(T2)
  indsR = IndsT1(ind(T1,1),ind(T2,2))
  return Tensor(Dense(vec(RM)),indsR)
end

function LinearAlgebra.exp(T::DenseTensor{ElT,2}) where {ElT}
  expTM = exp(matrix(T))
  return Tensor(Dense(vec(expTM)),inds(T))
end

function exphermitian(T::DenseTensor{ElT,2}) where {ElT}
  # exp(::Hermitian/Symmetric) returns Hermitian/Symmetric,
  # so extract the parent matrix
  expTM = parent(exp(Hermitian(matrix(T))))
  return Tensor(Dense(vec(expTM)),inds(T))
end

"""
  Spectrum
contains the (truncated) density matrix eigenvalue spectrum which is computed during a
decomposition done by `svd` or `eigenHermitian`. In addition stores the truncation error.
"""
struct Spectrum
  eigs::Vector{Float64}
  truncerr::Float64
end

eigs(s::Spectrum) = s.eigs
truncerror(s::Spectrum) = s.truncerr

function entropy(s::Spectrum)
  S = 0.0
  for p in eigs(s)
    p > 1e-13 && (S -= p*log(p))
  end
  return S
end

#svd of an order-2 tensor
function LinearAlgebra.svd(T::DenseTensor{ElT,2,IndsT};
                           kwargs...) where {ElT,IndsT}
  maxdim::Int = get(kwargs,:maxdim,minimum(dims(T)))
  mindim::Int = get(kwargs,:mindim,1)
  cutoff::Float64 = get(kwargs,:cutoff,0.0)
  absoluteCutoff::Bool = get(kwargs,:absoluteCutoff,false)
  doRelCutoff::Bool = get(kwargs,:doRelCutoff,true)
  fastSVD::Bool = get(kwargs,:fastSVD,false)

  if fastSVD
    MU,MS,MV = svd(matrix(T))
  else
    MU,MS,MV = svd_recursive(matrix(T))
  end
  conj!(MV)

  P = MS.^2
  truncerr,_ = truncate!(P;mindim=mindim,
                         maxdim=maxdim,
                         cutoff=cutoff,
                         absoluteCutoff=absoluteCutoff,
                         doRelCutoff=doRelCutoff)
  spec = Spectrum(P,truncerr)
  dS = length(P)
  if dS < length(MS)
    MU = MU[:,1:dS]
    resize!(MS,dS)
    MV = MV[:,1:dS]
  end

  # Make the new indices to go onto U and V
  u = eltype(IndsT)(dS)
  v = eltype(IndsT)(dS)
  Uinds = IndsT((ind(T,1),u))
  Sinds = IndsT((u,v))
  Vinds = IndsT((ind(T,2),v))
  U = Tensor(Dense(vec(MU)),Uinds)
  S = Tensor(Diag(MS),Sinds)
  V = Tensor(Dense(vec(MV)),Vinds)
  return U,S,V,spec
end

function eigenHermitian(T::DenseTensor{ElT,2,IndsT};
                        kwargs...) where {ElT,IndsT}
  ispossemidef::Bool = get(kwargs,:ispossemidef,false)
  maxdim::Int = get(kwargs,:maxdim,minimum(dims(T)))
  mindim::Int = get(kwargs,:mindim,1)
  cutoff::Float64 = get(kwargs,:cutoff,0.0)
  absoluteCutoff::Bool = get(kwargs,:absoluteCutoff,false)
  doRelCutoff::Bool = get(kwargs,:doRelCutoff,true)

  DM,UM = eigen(Hermitian(matrix(T)))

  # Sort by largest to smallest eigenvalues
  p = sortperm(DM; rev = true)
  DM = DM[p]
  UM = UM[:,p]

  if ispossemidef
    truncerr,_ = truncate!(DM;maxdim=maxdim,
                           cutoff=cutoff,
                           absoluteCutoff=absoluteCutoff,
                           doRelCutoff=doRelCutoff)
    dD = length(DM)
    if dD < size(UM,2)
      UM = UM[:,1:dD]
    end
  else
    dD = length(DM)
    truncerr = 0.0
  end
  spec = Spectrum(DM,truncerr)

  # Make the new indices to go onto U and V
  u = eltype(IndsT)(dD)
  v = eltype(IndsT)(dD)
  Uinds = IndsT((ind(T,1),u))
  Dinds = IndsT((u,v))
  U = Tensor(Dense(vec(UM)),Uinds)
  D = Tensor(Diag(DM),Dinds)
  return U,D,spec
end

function qr_positive(M::AbstractMatrix)
  sparseQ,R = qr(M)
  Q = convert(Matrix,sparseQ)
  nc = size(Q,2)
  for c=1:nc
    if real(R[c,c]) < 0.0
      R[c,c:end] *= -1
      Q[:,c] *= -1
    end
  end
  return (Q,R)
end

function LinearAlgebra.qr(T::DenseTensor{ElT,2,IndsT}
                          ;kwargs...) where {ElT,IndsT}
  positive = get(kwargs,:positive,false)
  # TODO: just call qr on T directly (make sure
  # that is fast)
  if positive
    QM,RM = qr_positive(matrix(T))
  else
    QM,RM = qr(matrix(T))
  end
  # Make the new indices to go onto Q and R
  q,r = inds(T)
  q = dim(q) < dim(r) ? sim(q) : sim(r)
  Qinds = IndsT((ind(T,1),q))
  Rinds = IndsT((q,ind(T,2)))
  Q = Tensor(Dense(vec(Matrix(QM))),Qinds)
  R = Tensor(Dense(vec(RM)),Rinds)
  return Q,R
end

function polar(T::DenseTensor{ElT,2,IndsT}) where {ElT,IndsT}
  QM,RM = polar(matrix(T))
  dim = size(QM,2)
  # Make the new indices to go onto Q and R
  q = eltype(IndsT)(dim)
  # TODO: use push/pushfirst instead of a constructor
  # call here
  Qinds = IndsT((ind(T,1),q))
  Rinds = IndsT((q,ind(T,2)))
  Q = Tensor(Dense(vec(QM)),Qinds)
  R = Tensor(Dense(vec(RM)),Rinds)
  return Q,R
end

