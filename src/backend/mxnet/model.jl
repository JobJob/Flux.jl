using Flux: batchone, rebatch

type Graph
  node::mx.SymbolicNode
  params::Dict{Symbol,Any}
  stacks::Dict{Any,Any}
end

type Model <: Flux.Model
  model::Any
  graph::Graph
  grads::Dict{Symbol,Any}
  exec::mx.Executor
end

tond(xs::AArray) = copy!(mx.zeros(size(xs)), xs)

ndzero!(xs::mx.NDArray) = copy!(xs, mx.zeros(size(xs)))

function mxargs(args)
  isempty(args) && return Dict{Symbol,mx.NDArray}()
  map(args) do kv
    arg, value = kv
    arg => tond(value)
  end
end

function mxgrads(mxargs)
  isempty(mxargs) && return Dict{Symbol,mx.NDArray}()
  map(mxargs) do kv
    arg, value = kv
    arg => mx.zeros(size(value))
  end
end

function loadparams!(model::Model)
  for (name, arr) in model.exec.arg_dict
    haskey(model.graph.params, name) && copy!(arr, model.graph.params[name])
  end
  return model
end

function mxnet(model::Flux.Model, input)
  graph = tograph(model, mx.Variable(:input))
  args = merge(mxargs(graph.params), Dict(:input => mx.zeros(input)))
  grads = mxgrads(args)
  model = @mxerr graph.stacks Model(model, graph, grads,
                                    mx.bind(graph.node, args = args,
                                            args_grad = grads,
                                            grad_req = mx.GRAD_ADD))
  loadparams!(model)
  return model
end

# MNet batches on last dimension
rebatch_last(xs) = permutedims(xs, (2:ndims(xs)..., 1))
rebatch_first(xs) = permutedims(xs, (ndims(xs), 1:ndims(xs)-1...))

function runmodel(model::Model, input)
  copy!(model.exec.arg_dict[:input], input)
  mx.forward(model.exec, is_train = true)
  copy(model.exec.outputs[1])
end

(m::Model)(x::Batch) = rebatch(rebatch_first(runmodel(m, rebatch_last(rawbatch(x)))))

(m::Model)(x) = first(m(batchone(x)))

function Flux.back!(model::Model, Δ, x)
  ndzero!(model.grads[:input])
  mx.backward(model.exec, tond(Δ))
  copy(model.grads[:input])
end

function Flux.update!(model::Model, η)
  for (arg, grad) in zip(model.exec.arg_arrays, model.exec.grad_arrays)
    mx.@nd_as_jl rw = (arg, grad) begin
      arg .-= grad .* η
      grad[:] = 0
    end
  end
  return model
end

# MX FeedForward interface

type SoftmaxOutput
  name::Symbol
end

graph(s::SoftmaxOutput, xs) = mx.SoftmaxOutput(xs, name = s.name)

function rewrite_softmax(model, name)
  model == softmax && return SoftmaxOutput(name)
  g = Flux.graph(model)
  (g == nothing || g.value ≠ softmax || DataFlow.nin(g) ≠ 1) && error("mx.FeedForward models must end with `softmax`")
  return Flux.Capacitor(vertex(SoftmaxOutput(name), g[1]))
end

function mx.FeedForward(model::Flux.Model; input = :data, label = :softmax, context = mx.cpu())
  model = rewrite_softmax(model, label)
  graph = tograph(model, mx.Variable(input), feedforward=true)
  ff = mx.FeedForward(graph.node, context = context)
  isempty(graph.params) || (ff.arg_params = mxargs(graph.params))
  return ff
end
