"""Project a panel coordinate into the full figure's pixel coordinate system."""
function figure_pixel(axis, xy)
    # Makie's projection returns subscene-local pixels; the viewport places them
    # in the parent figure. Keep the nonlinear data transform before projection.
    transformed = Makie.apply_transform(Makie.transform_func(axis.scene),
        Point3d(xy[1], xy[2], 0))
    point = Makie.project(axis.scene, transformed)
    origin = minimum(Makie.viewport(axis.scene)[])
    (point[1] + origin[1], point[2] + origin[2])
end
