/***************************************************************************
 # Arvo's closed-form projected solid angle, with horizon clipping
 #
 # Original: render_common.h :484  tri_projected_solid_angle()
 #
 # Why horizon clipping matters (excerpt gotcha 3):
 #   The MC estimator A only counts samples with cos_x > 0. If the analytic U also
 #   counted the part below the horizon, E[A] != U, the control variate would no
 #   longer have zero mean, and an RMSE floor would remain that no spp count removes.
 #   So the spherical triangle is clipped against the great circle
 #   {w : dot(w, n_x) = 0}.
 **************************************************************************/
__exported import Utils.Math.MathHelpers;

/**
 * Projected solid angle of triangle (v0,v1,v2) seen from shading point x with normal
 * n_x. Zero if the triangle is back-facing or entirely below the horizon.
 *
 * For the returned phi,  integral_{tri} cos_x / d^2 dA = phi  holds, so
 *   U_k = f * Le_k * phi_k
 * is the exact unshadowed contribution of that triangle.
 */
float triProjectedSolidAngle(const float3 v0, const float3 v1, const float3 v2, const float3 x, const float3 n_x)
{
    float3 d0 = v0 - x;
    float3 d1 = v1 - x;
    float3 d2 = v2 - x;
    float L0 = length(d0), L1 = length(d1), L2 = length(d2);
    if (L0 < 1e-6f || L1 < 1e-6f || L2 < 1e-6f)
        return 0.f;

    float3 u0 = d0 / L0, u1 = d1 / L1, u2 = d2 / L2;

    float3 nyRaw = cross(v1 - v0, v2 - v0);
    float nn = length(nyRaw);
    if (nn < 1e-12f)
        return 0.f;

    // One-sided emitter: zero if the receiver is behind the triangle.
    float dn = dot(d0, nyRaw) / nn;
    if (abs(dn) < 1e-4f)
        return 0.f;
    if (dn > 0.f)
        return 0.f;

    float h0 = dot(u0, n_x), h1 = dot(u1, n_x), h2 = dot(u2, n_x);
    const float eps = 1e-4f;
    int above = (h0 > eps ? 1 : 0) + (h1 > eps ? 1 : 0) + (h2 > eps ? 1 : 0);
    if (above == 0)
        return 0.f;

    // Clip away everything below the horizon. The result has at most 4 vertices.
    float3 poly[4];
    int n = 0;
    if (above == 3)
    {
        poly[0] = u0;
        poly[1] = u1;
        poly[2] = u2;
        n = 3;
    }
    else
    {
        float3 us[3] = {u0, u1, u2};
        float hs[3] = {h0, h1, h2};
        for (int i = 0; i < 3; ++i)
        {
            int j = (i + 1) % 3;
            bool ai = hs[i] > eps;
            bool aj = hs[j] > eps;
            if (ai)
                poly[n++] = us[i];
            if (ai != aj)
            {
                float t = hs[i] / (hs[i] - hs[j]);
                poly[n++] = normalize(us[i] * (1.f - t) + us[j] * t);
            }
        }
    }
    if (n < 3)
        return 0.f;

    // Arvo: projected solid angle of a spherical polygon.
    float s = 0.f;
    for (int i = 0; i < n; ++i)
    {
        int j = (i + 1) % n;
        float3 cr = cross(poly[i], poly[j]);
        float crn = length(cr);
        if (crn > 1e-12f)
        {
            float th = atan2(crn, dot(poly[i], poly[j]));
            s += th * (dot(cr, n_x) / crn);
        }
    }
    return abs(0.5f * s);
}
