"""
    ReluVal(max_iter::Int64, tree_search::Symbol)

ReluVal combines symbolic reachability analysis with iterative interval refinement to minimize over-approximation of the reachable set.

# Problem requirement
1. Network: any depth, ReLU activation
2. Input: hyperrectangle
3. Output: AbstractPolytope

# Return
`CounterExampleResult` or `ReachabilityResult`

# Method
Symbolic reachability analysis and iterative interval refinement (search).
- `max_iter` default `10`.
- `tree_search` default `:DFS` - depth first search.

# Property
Sound but not complete.

# Reference
[S. Wang, K. Pei, J. Whitehouse, J. Yang, and S. Jana,
"Formal Security Analysis of Neural Networks Using Symbolic Intervals,"
*CoRR*, vol. abs/1804.10829, 2018. arXiv: 1804.10829.](https://arxiv.org/abs/1804.10829)

[https://github.com/tcwangshiqi-columbia/ReluVal](https://github.com/tcwangshiqi-columbia/ReluVal)
"""
@with_kw struct ReluVal <: Solver
    max_iter::Int64     = 10
    tree_search::Symbol = :DFS # only :DFS/:BFS allowed? If so, we should assert this.
end

# Data to be passed during forward_layer
struct SymbolicIntervalMask
    sym::SymbolicInterval
    LΛ::Vector{Vector{Bool}}
    UΛ::Vector{Vector{Bool}}
end

function init_symbolic_mask(interval)
    n = dim(interval)
    I = Matrix{Float64}(LinearAlgebra.I(n))
    Z = zeros(n)
    symbolic_input = SymbolicInterval([I Z], [I Z], interval)
    symbolic_mask = SymbolicIntervalMask(symbolic_input,
                                         Vector{Vector{Bool}}(),
                                         Vector{Vector{Bool}}())
end

function solve(solver::ReluVal, problem::Problem)

    reach = forward_network(solver, problem.network, init_symbolic_mask(problem.input))
    result = check_inclusion(reach.sym, problem.output, problem.network)
    result.status === :unknown || return result

    reach_list = [reach]

    for i in 2:solver.max_iter

        isempty(reach_list) && return BasicResult(:holds)

        reach = select!(reach_list, solver.tree_search)

        intervals = bisect_interval_by_max_smear(problem.network, reach)

        for interval in intervals
            reach = forward_network(solver, problem.network, init_symbolic_mask(interval))
            result = check_inclusion(reach.sym, problem.output, problem.network)

            if result === :violated
                return result
            elseif result === :unknown
                push!(reach_list, reach)
            end
        end
    end
    return BasicResult(:unknown)
end

function bisect_interval_by_max_smear(nnet::Network, reach::SymbolicIntervalMask)
    LG, UG = get_gradient_bounds(nnet, reach.LΛ, reach.UΛ)
    feature, monotone = get_max_smear_index(nnet, reach.sym.interval, LG, UG) #monotonicity not used in this implementation.
    return split_interval(reach.sym.interval, feature)
end

function select!(reach_list, tree_search)
    if tree_search == :BFS
        reach = popfirst!(reach_list)
    elseif tree_search == :DFS
        reach = pop!(reach_list)
    else
        throw(ArgumentError(":$tree_search is not a valid tree search strategy"))
    end
    return reach
end

function symbol_to_concrete(reach::SymbolicInterval{<:Hyperrectangle})
    lower = [lower_bound(l, reach.interval) for l in eachrow(reach.Low)]
    upper = [upper_bound(u, reach.interval) for u in eachrow(reach.Up)]
    return Hyperrectangle(low = lower, high = upper)
end

function check_inclusion(reach::SymbolicInterval{<:Hyperrectangle}, output, nnet::Network)
    reachable = symbol_to_concrete(reach)

    issubset(reachable, output) && return BasicResult(:holds)

    # Sample the middle point
    middle_point = center(reach.interval)
    y = compute_output(nnet, middle_point)
    y ∈ output || return CounterExampleResult(:violated, middle_point)

    return BasicResult(:unknown)
end

function forward_layer(solver::ReluVal, layer::Layer, input)
    return forward_act(solver, forward_linear(input, layer), layer)
end

# Symbolic forward_linear
function forward_linear(input::SymbolicIntervalMask, layer::Layer)
    (W, b) = (layer.weights, layer.bias)
    output_Low, output_Up = interval_map(W, input.sym.Low, input.sym.Up)
    output_Up[:, end] += b
    output_Low[:, end] += b
    sym = SymbolicInterval(output_Low, output_Up, input.sym.interval)
    return SymbolicIntervalMask(sym, input.LΛ, input.UΛ)
end

# Symbolic forward_act
function forward_act(::ReluVal, input::SymbolicIntervalMask, layer::Layer{ReLU})

    interval = input.sym.interval
    Low, Up = input.sym.Low, input.sym.Up

    n_node, n_input = size(Up)
    output_Low, output_Up = copy(Low), copy(Up)
    LΛᵢ, UΛᵢ = falses(n_node), trues(n_node)

    for j in 1:n_node
        # Loop-local variable bindings for notational convenience.
        # These are direct views into the rows of the parent arrays.
        lowᵢⱼ, upᵢⱼ, out_lowᵢⱼ, out_upᵢⱼ = @views Low[j, :], Up[j, :], output_Low[j, :], output_Up[j, :]

        # If the upper bound is negative, set the gradient mask to 0
        # and zero out future layer dependency
        if upper_bound(upᵢⱼ, interval) <= 0
            LΛᵢ[j], UΛᵢ[j] = 0, 0
            out_lowᵢⱼ .= 0
            out_upᵢⱼ .= 0

        # If the lower bound is positive, the gradient mask should be 1
        elseif lower_bound(lowᵢⱼ, interval) >= 0
            LΛᵢ[j], UΛᵢ[j] = 1, 1

        # if the activation bounds overlap 0, concretize by setting
        # the generators to 0, except the bias term.
        else
            LΛᵢ[j], UΛᵢ[j] = 0, 1
            out_lowᵢⱼ .= 0
            if lower_bound(upᵢⱼ, interval) < 0
                out_upᵢⱼ .= 0
                out_upᵢⱼ[end] = upper_bound(upᵢⱼ, interval)
            end
        end
    end

    sym = SymbolicInterval(output_Low, output_Up, interval)
    LΛ = push!(copy(input.LΛ), LΛᵢ)
    UΛ = push!(copy(input.UΛ), UΛᵢ)
    return SymbolicIntervalMask(sym, LΛ, UΛ)
end

# Symbolic forward_act
function forward_act(::ReluVal, input::SymbolicIntervalMask, layer::Layer{Id})
    sym = input.sym
    n_node = size(input.sym.Up, 1)
    LΛ = push!(input.LΛ, trues(n_node))
    UΛ = push!(input.UΛ, trues(n_node))
    return SymbolicIntervalMask(sym, LΛ, UΛ)
end

function get_max_smear_index(nnet::Network, input::Hyperrectangle, LG::Matrix, UG::Matrix)

    smear(lg, ug, r) = sum(max.(abs.(lg), abs.(ug))) * r

    ind = argmax(smear.(eachcol(LG), eachcol(UG), input.radius))
    monotone = all(>(0), LG[:, ind] .* UG[:, ind]) # NOTE should it be >= 0 instead?

    return ind, monotone
end

function _bound(map::AbstractVector, input::Hyperrectangle, which_bound::Symbol)
    a, b = map[1:end-1], map[end]

    if which_bound === :lower
        bound = max.(a, 0)' * low(input) +
                min.(a, 0)' * high(input) + b
    elseif which_bound === :upper
        bound = max.(a, 0)' * high(input) +
                min.(a, 0)' * low(input) + b
    end

    return bound
end

upper_bound(map, input) = _bound(map, input, :upper)
lower_bound(map, input) = _bound(map, input, :lower)


# Concrete forward_linear
# function forward_linear_concrete(input::Hyperrectangle, W::Matrix{Float64}, b::Vector{Float64})
#     n_output = size(W, 1)
#     output_upper = zeros(n_output)
#     output_lower = zeros(n_output)
#     for j in 1:n_output
#         output_upper[j] = upper_bound(W[j, :], input) + b[j]
#         output_lower[j] = lower_bound(W[j, :], input) + b[j]
#     end
#     output = Hyperrectangle(low = output_lower, high = output_upper)
#     return output
# end

# Concrete forward_act
# function forward_act(input::Hyperrectangle)
#     input_upper = high(input)
#     input_lower = low(input)
#     output_upper = zeros(dim(input))
#     output_lower = zeros(dim(input))
#     mask_upper = ones(Int, dim(input))
#     mask_lower = zeros(Int, dim(input))
#     for i in 1:dim(input)
#         if input_upper[i] <= 0
#             mask_upper[i] = mask_lower[i] = 0
#             output_upper[i] = output_lower[i] = 0.0
#         elseif input_lower[i] >= 0
#             mask_upper[i] = mask_lower[i] = 1
#         else
#             output_lower[i] = 0.0
#         end
#     end
#     return (output_lower, output_upper, mask_lower, mask_upper)
# end

# This function is similar to forward_linear
# function backward_linear(Low::Matrix{Float64}, Up::Matrix{Float64}, W::Matrix{Float64})
#     n_output, n_input = size(W)
#     n_symbol = size(Low, 2) - 1

#     output_Low = zeros(n_output, n_symbol + 1)
#     output_Up = zeros(n_output, n_symbol + 1)
#     for k in 1:n_symbol + 1
#         for j in 1:n_output
#             for i in 1:n_input
#                 output_Up[j, k] += ifelse(W[j, i]>0, W[j, i] * Up[i, k], W[j, i] * Low[i, k])
#                 output_Low[j, k] += ifelse(W[j, i]>0, W[j, i] * Low[i, k], W[j, i] * Up[i, k])
#             end
#         end
#     end
#     return (output_Low, output_Up)
# end