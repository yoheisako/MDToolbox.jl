function sp_delta_pmf(umbrella_center, data_k, kbt, spring_constant)
    nframe = size(data_k[1], 1)
    K = size(data_k, 1)
    delta_pmf      = CuArrays.zeros(Float64, nframe, K)
    bias_potential = CuArrays.zeros(Float64, nframe, K)

    for k = 1:K
        dd_mean = mean(data_k[k], dims=1)
        dd_cov = cov(data_k[k])
        dd_inv = dd_cov \ CuArray{Float64}(I, size(dd_cov))
        bias_potential = spring_constant * sum((data_k[k] .- umbrella_center[k:k, :]).^2, dims=2)
        d = data_k[k] .- dd_mean
        tmp_pmf = kbt .* (-0.5 .* sum((d * dd_inv) .* d, dims=2))
        delta_pmf[:, k:k] .= .- tmp_pmf .+ tmp_pmf[1, 1] .- bias_potential .+ bias_potential[1, 1]
    end

    return delta_pmf
end

#######################################
function sp_design_matrix(umbrella_centers, sim_all_datas, stride, sigma_g)
    nframe = size(sim_all_datas[1], 1)
    subframes = range(1, stop=nframe, step=stride)
    design_matrix = CuArrays.zeros(Float64, length(subframes) * size(umbrella_centers, 1), size(umbrella_centers, 1))

    for i = 1:size(umbrella_centers, 1)
        for k = 1:size(umbrella_centers, 1)
            diff = exp.(- 0.5 .* sum((sim_all_datas[i] .- umbrella_centers[k:k, :]).^2, dims=2) ./ sigma_g.^2)
            diff .-= exp(- 0.5 .* sum((sim_all_datas[i][1, :] .- umbrella_centers[k, :]).^2) ./ sigma_g.^2)
            design_matrix[(length(subframes)*(i-1)+1):(i*length(subframes)), k] = diff
        end
    end

    return design_matrix
end

#######################################
function sp_design_matrix_xyz(umbrella_centers, sim_all_datas, sigma_g)
    nframe = size(sim_all_datas[1], 1)
    numbrella = size(umbrella_centers, 1)
    natom = Int(size(umbrella_centers, 2) / 3)
    design_matrix = CuArrays.zeros(Float64, nframe * numbrella, numbrella * natom)

    for i = 1:size(umbrella_centers, 1)
        for k = 1:size(umbrella_centers, 1)
            diff_x1 = exp.(- 0.5 .* ((sim_all_datas[i][:, 1:3:end]   .- umbrella_centers[k:k, 1:3:end]).^2) ./ sigma_g.^2)
            diff_y1 = exp.(- 0.5 .* ((sim_all_datas[i][:, 2:3:end]   .- umbrella_centers[k:k, 2:3:end]).^2) ./ sigma_g.^2)
            diff_z1 = exp.(- 0.5 .* ((sim_all_datas[i][:, 3:3:end]   .- umbrella_centers[k:k, 3:3:end]).^2) ./ sigma_g.^2)
            diff_x2 = exp.(- 0.5 .* ((sim_all_datas[i][1:1, 1:3:end] .- umbrella_centers[k:k, 1:3:end]).^2) ./ sigma_g.^2)
            diff_y2 = exp.(- 0.5 .* ((sim_all_datas[i][1:1, 2:3:end] .- umbrella_centers[k:k, 2:3:end]).^2) ./ sigma_g.^2)
            diff_z2 = exp.(- 0.5 .* ((sim_all_datas[i][1:1, 3:3:end] .- umbrella_centers[k:k, 3:3:end]).^2) ./ sigma_g.^2)
            design_matrix[(nframe*(i-1)+1):(nframe*i), (natom*(k-1)+1):(natom*k)] .= (diff_x1 .* diff_y1 .* diff_z1) .- (diff_x2 .* diff_y2 .* diff_z2)
        end
    end
    return design_matrix
end

#######################################
function funcS(cov, lambda)
    return sign(cov) * max((abs(cov) - lambda), 0)
end

#######################################
"""
Alternating Direction Method of Multipliers (ADMM) for solving lasso
"""
function sp_admm(y, X, lambda=0.1; rho=1.0, condition=1e-5, iter_max=10000)
    ncolumn = size(X, 2);
    beta = CuArrays.zeros(Float64, ncolumn)
    gamma = CuArrays.zeros(Float64, ncolumn)
    my = CuArrays.zeros(Float64, ncolumn)

    old_beta = copy(beta)
    old_gamma = copy(gamma)
    old_my = copy(my)

    U, S, V = svd(X' * X + ((CuArray{Float64}(I, (ncolumn, ncolumn)) .* (ncolumn .* rho))))
    inverse_M = V * inv(Diagonal(S)) * U'
    const_num = inverse_M

    max_diff = 100
    cnt::Int = 1
    X_y = X' * y
    while max_diff > condition
        beta .= const_num * (X_y .+ ((gamma .- (my .* (1.0 ./ rho))) .* (ncolumn .* rho)))
        gamma .= funcS.(beta .+ (my .* (1.0 ./ rho)), lambda ./ rho)
        my .= my .+ ((beta .- gamma) .* rho)

        max_diff = maximum(abs.(gamma .- old_gamma))
        old_beta .= beta
        old_gamma .= gamma
        old_my .= my
        cnt += 1
        if cnt > iter_max
            break
        end
    end

    println("[ Cycle Count = ", cnt, " ]")
    println("[ Complete Condition ]")
    println("  Max Differ = ", max_diff)
    println("\n")

    return gamma
end

#######################################
function sp_standardize!(M)
    mean_M = mean(M, dims=1)
    std_M = std(M, dims=1)
    M .= (M .- mean_M) ./ std_M
    return mean_M, std_M
end

#######################################
function sp_standardize(M)
    mean_M = mean(M, dims=1)
    std_M = std(M, dims=1)
    M_standardized = (M .- mean_M) ./ std_M
    return M_standardized, mean_M, std_M
end

#######################################
function sp_cumulate_pmf_atom(x, weight, umbrella_center, sigma_rdf, mean_M, std_M)
    ndim = size(umbrella_center, 2)
    natom = Int(ndim / 3)
    K = size(umbrella_center, 1)
    nframe = size(x, 1)

    pmf = zeros(Float64, nframe);
    for iframe = 1:nframe
        sum_rdf = 0.0
        for k = 1:K
            for iatom = 1:natom
                index = (k-1)*natom + iatom
                index3 = ((iatom-1)*3 + 1):(iatom*3)
                tmp = (exp(sum(- 0.5 .* (x[iframe, index3] .- umbrella_center[k, index3]).^2 ./ sigma_rdf.^2))  - mean_M[index]) / std_M[index]
                sum_rdf += tmp * weight[index]
            end
        end
        pmf[iframe] = sum_rdf
    end

    return pmf .- minimum(pmf)
end

#######################################
function sp_lasso(M, delta_pmf, sigma_rdf)
end