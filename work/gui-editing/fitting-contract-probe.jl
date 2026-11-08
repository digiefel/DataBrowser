module FittingContractProbe
using LinearAlgebra

function run()
    # Julia keyword dispatch validates a call, not the intended free-parameter set.
    with_default(x; a=2.0, b) = a*x+b
    accepts_extras(x; a, kwargs...) = a*x
    println("omitted_free_parameter_uses_default=",with_default(1.0; b=1.0))
    println("extra_free_parameter_can_be_ignored=",accepts_extras(1.0; a=2.0, typo=100.0))

    h=0.01; f(a,b)=a*b
    d2a=(f(1+h,1)-2f(1,1)+f(1-h,1))/h^2
    d2b=(f(1,1+h)-2f(1,1)+f(1,1-h))/h^2
    mixed=(f(1+h,1+h)-f(1+h,1-h)-f(1-h,1+h)+f(1-h,1-h))/(4h^2)
    println("product_model_curvature=",(; d2a,d2b,mixed))
    println("negative_lifetime_is_numerically_valid=",exp(-1.0 / -2.0))
    x=collect(1.0:4.0)
    println("square_parameter_opposite_signs_identical=",all((2.0^2).*x .== ((-2.0)^2).*x))
    println("square_parameter_jacobian_rank_at_a2=",rank(reshape(4 .* x,:,1)))

    X=hcat(ones(2),[1.0,2.0]); y=[3.0,5.0]; coefficients=X\y
    ν=length(y)-size(X,2)
    println("two_point_line=",(; coefficients,rank=rank(X),dof=ν,residual_variance=sum(abs2,y-X*coefficients)/ν))
    println("repeated_x_rank=",rank(hcat(ones(4),fill(2.0,4))))
    # Exact t_(0.975, 2), derived from the t distribution with two degrees of freedom.
    u=0.95; t95=u*sqrt(2/(1-u*u))
    println("four_point_two_parameter_95CI_SE_multiplier=",t95)

    merged=(;(x=[1.0,2.0],)...,(x=3.0,)...)
    println("naive_result_parameter_collision=",merged)
    println("missing_interpolation=","Rc=$(missing)")
    try
        getproperty(missing,:x)[end]
    catch error
        println("failed_result_endpoint_error=",typeof(error))
    end
    x4=collect(1.0:4.0); X4=hcat(ones(4),x4); y4=[3.0,5.2,6.8,9.0]
    p=X4\y4; R=Matrix(qr(X4).R); Rinv=inv(R); C=Rinv*Rinv'
    gradient=[1.0,2.5]
    println("correlated_prediction_variance=",dot(gradient,C*gradient))
    println("independent_parameter_variance=",sum(gradient.^2 .* diag(C)))
    return nothing
end
end
