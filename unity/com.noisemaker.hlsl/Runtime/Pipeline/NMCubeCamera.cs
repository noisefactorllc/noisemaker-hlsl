// NMCubeCamera.cs — cube-face camera math for seamless cubemap rendering.
//
// A faithful port of the reference shaders/src/renderer/cubeCamera.js. The camera
// sits at the volume origin looking OUT along each of the 6 axes; a face has an
// orthonormal basis (right, up, forward) and a face pixel at (u,v) in [-1,1]^2 maps
// to dir = normalize(u*right - v*up + forward) (90-degree frustum). Adjacent faces
// share identical edge directions — the source of cube seamlessness.
//
// faceBasisMat3 returns the COLUMN-MAJOR [right | up | forward] 9-tuple — exactly the
// layout the reference uploads via gl.uniformMatrix3fv(loc, false, value). The C#
// runtime binds it as a float4x4 (UniformBinder.BindMatrix3) and the cube shaders
// recover the columns explicitly. GL cubemap face order: +X,-X,+Y,-Y,+Z,-Z, which
// matches UnityEngine.CubemapFace indices (PositiveX=0 .. NegativeZ=5).

namespace Noisemaker.Hlsl
{
    public static class NMCubeCamera
    {
        public const int FaceCount = 6;

        // Per-face file/identifier names (reference cubeExport.faceFileNames order).
        public static readonly string[] FaceNames = { "px", "nx", "py", "ny", "pz", "nz" };

        // forward = view direction; up = face "up" (reference CUBE_FACES).
        private static readonly double[][] Forward =
        {
            new double[] {  1,  0,  0 },  // +X
            new double[] { -1,  0,  0 },  // -X
            new double[] {  0,  1,  0 },  // +Y
            new double[] {  0, -1,  0 },  // -Y
            new double[] {  0,  0,  1 },  // +Z
            new double[] {  0,  0, -1 },  // -Z
        };
        private static readonly double[][] Up =
        {
            new double[] {  0, -1,  0 },  // +X
            new double[] {  0, -1,  0 },  // -X
            new double[] {  0,  0,  1 },  // +Y
            new double[] {  0,  0, -1 },  // -Y
            new double[] {  0, -1,  0 },  // +Z
            new double[] {  0, -1,  0 },  // -Z
        };

        // Column-major [right | up | forward] 9-tuples, one per face. Computed once via
        // right = cross(up, forward) so (right, up, forward) is right-handed — identical
        // to cubeCamera.faceBasisMat3 / CUBE_FACE_BASES.
        public static readonly double[][] FaceBases = BuildFaceBases();

        private static double[][] BuildFaceBases()
        {
            var bases = new double[FaceCount][];
            for (int f = 0; f < FaceCount; f++)
            {
                double[] fwd = Forward[f];
                double[] up = Up[f];
                // right = cross(up, forward).
                double rx = up[1] * fwd[2] - up[2] * fwd[1];
                double ry = up[2] * fwd[0] - up[0] * fwd[2];
                double rz = up[0] * fwd[1] - up[1] * fwd[0];
                bases[f] = new double[]
                {
                    rx, ry, rz,           // column 0 — right
                    up[0], up[1], up[2],  // column 1 — up
                    fwd[0], fwd[1], fwd[2] // column 2 — forward
                };
            }
            return bases;
        }
    }
}
