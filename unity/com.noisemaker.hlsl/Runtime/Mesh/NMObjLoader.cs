// NMObjLoader.cs — pure Wavefront OBJ parser. 1:1 port of the reference
// shaders/src/runtime/obj-parser.js (parseOBJ + packMeshDataForTextures +
// computeFaceNormals). NO Unity types — produces flat float[] arrays only, so it
// is testable headless and shared by the upload path (NMMeshData.UploadObj).
//
// Parity notes vs obj-parser.js:
//   * Indices are 1-based in OBJ; converted to 0-based. Negative (relative) indices
//     are NOT supported by the reference parser, so neither here (parseInt of "-2"
//     yields a negative 0-based index that fails the >=0 guard -> default vertex).
//   * Faces are fan-triangulated with REVERSED winding (v0, v2, v1) — the reference
//     flips OBJ CW to GL CCW. The HLSL render path culls BACK with frontFace CCW, so
//     this winding must be preserved exactly (reference render.vert / webgl2 triangles).
//   * When no vn are present, smooth normals are computed by averaging adjacent face
//     normals keyed on position rounded to 1e-4 — identical to computeFaceNormals.
//   * Float parse uses invariant culture (OBJ uses '.' decimals); a failed parse
//     yields 0 (matches JS `parseFloat(...) || 0`).
//
// This file is correct-by-construction (no Unity/Node available in this session).
// TODO(verify): diff packed texel output against the JS reference on the bundled
// share/meshes/*.obj once a Unity/Node harness exists.

using System.Collections.Generic;
using System.Globalization;

namespace Noisemaker.Hlsl
{
    // De-indexed triangle data: positions/normals are xyz per vertex, uvs uv per
    // vertex; VertexCount == positions.Length/3 == triangles*3.
    public struct NMMeshArrays
    {
        public float[] Positions; // xyz interleaved as triangles
        public float[] Normals;   // xyz per vertex
        public float[] Uvs;       // uv per vertex
        public int VertexCount;   // triangles * 3
    }

    public static class NMObjLoader
    {
        // parseOBJ(objText) — reference obj-parser.js.
        public static NMMeshArrays ParseObj(string objText)
        {
            // Raw indexed data.
            var rawPositions = new List<float[]>(); // vec3
            var rawNormals = new List<float[]>();   // vec3
            var rawUVs = new List<float[]>();        // vec2

            // De-indexed triangle data.
            var positions = new List<float>();
            var normals = new List<float>();
            var uvs = new List<float>();

            if (objText == null) objText = string.Empty;
            // Split on \n; \r is stripped by the per-line trim (handles CRLF).
            string[] lines = objText.Split('\n');

            for (int li = 0; li < lines.Length; li++)
            {
                string line = lines[li].Trim();
                if (line.Length == 0 || line[0] == '#') continue;

                string[] parts = SplitWhitespace(line);
                if (parts.Length == 0) continue;
                string cmd = parts[0];

                if (cmd == "v")
                {
                    rawPositions.Add(new float[] {
                        ParseF(parts, 1), ParseF(parts, 2), ParseF(parts, 3)
                    });
                }
                else if (cmd == "vn")
                {
                    rawNormals.Add(new float[] {
                        ParseF(parts, 1), ParseF(parts, 2), ParseF(parts, 3)
                    });
                }
                else if (cmd == "vt")
                {
                    rawUVs.Add(new float[] {
                        ParseF(parts, 1), ParseF(parts, 2)
                    });
                }
                else if (cmd == "f")
                {
                    // f v1/vt1/vn1 v2/vt2/vn2 ...  (forms: v, v/vt, v//vn, v/vt/vn)
                    var faceVerts = new List<int[]>(); // {vIdx, vtIdx, vnIdx}
                    for (int i = 1; i < parts.Length; i++)
                    {
                        string[] idx = parts[i].Split('/');
                        // 1-based -> 0-based. -1 marks "absent" (matches JS ternary).
                        int vIdx = ParseIndex(idx, 0);
                        int vtIdx = idx.Length > 1 && idx[1].Length > 0 ? ParseIndex(idx, 1) : -1;
                        int vnIdx = idx.Length > 2 && idx[2].Length > 0 ? ParseIndex(idx, 2) : -1;
                        faceVerts.Add(new int[] { vIdx, vtIdx, vnIdx });
                    }

                    // Fan-triangulate with REVERSED winding (v0, v2, v1).
                    for (int i = 1; i < faceVerts.Count - 1; i++)
                    {
                        int[] v0 = faceVerts[0];
                        int[] v1 = faceVerts[i];
                        int[] v2 = faceVerts[i + 1];
                        AddVertex(v0, rawPositions, rawNormals, rawUVs, positions, normals, uvs);
                        AddVertex(v2, rawPositions, rawNormals, rawUVs, positions, normals, uvs);
                        AddVertex(v1, rawPositions, rawNormals, rawUVs, positions, normals, uvs);
                    }
                }
            }

            int vertexCount = positions.Count / 3;

            // No vn supplied -> compute smooth face-averaged normals in place.
            if (rawNormals.Count == 0 && vertexCount > 0)
                ComputeFaceNormals(positions, normals);

            return new NMMeshArrays
            {
                Positions = positions.ToArray(),
                Normals = normals.ToArray(),
                Uvs = uvs.ToArray(),
                VertexCount = vertexCount
            };
        }

        private static void AddVertex(int[] v,
            List<float[]> rawPositions, List<float[]> rawNormals, List<float[]> rawUVs,
            List<float> positions, List<float> normals, List<float> uvs)
        {
            int vIdx = v[0], vtIdx = v[1], vnIdx = v[2];

            if (vIdx >= 0 && vIdx < rawPositions.Count)
            {
                float[] p = rawPositions[vIdx];
                positions.Add(p[0]); positions.Add(p[1]); positions.Add(p[2]);
            }
            else { positions.Add(0f); positions.Add(0f); positions.Add(0f); }

            if (vnIdx >= 0 && vnIdx < rawNormals.Count)
            {
                float[] n = rawNormals[vnIdx];
                normals.Add(n[0]); normals.Add(n[1]); normals.Add(n[2]);
            }
            else { normals.Add(0f); normals.Add(0f); normals.Add(1f); } // placeholder

            if (vtIdx >= 0 && vtIdx < rawUVs.Count)
            {
                float[] t = rawUVs[vtIdx];
                uvs.Add(t[0]); uvs.Add(t[1]);
            }
            else { uvs.Add(0f); uvs.Add(0f); }
        }

        // computeFaceNormals — smooth normals by averaging adjacent face normals,
        // keyed on position rounded to 1e-4 (reference obj-parser.js step 1-4).
        private static void ComputeFaceNormals(List<float> positions, List<float> normals)
        {
            int vertexCount = positions.Count / 3;
            int triangleCount = vertexCount / 3;

            // Step 1: face normals for each triangle (a=v0, b=v2, c=v1 reversed order).
            var faceNormals = new float[triangleCount * 3];
            for (int tri = 0; tri < triangleCount; tri++)
            {
                int i0 = tri * 9;        // v0
                int i1 = i0 + 3;         // v2
                int i2 = i0 + 6;         // v1

                float ax = positions[i0], ay = positions[i0 + 1], az = positions[i0 + 2];
                float bx = positions[i1], by = positions[i1 + 1], bz = positions[i1 + 2];
                float cx = positions[i2], cy = positions[i2 + 1], cz = positions[i2 + 2];

                float e1x = bx - ax, e1y = by - ay, e1z = bz - az;
                float e2x = cx - ax, e2y = cy - ay, e2z = cz - az;

                // e1 x e2 -> outward normal for CCW.
                float nx = e1y * e2z - e1z * e2y;
                float ny = e1z * e2x - e1x * e2z;
                float nz = e1x * e2y - e1y * e2x;

                double len = System.Math.Sqrt(nx * nx + ny * ny + nz * nz);
                if (len > 0.0001)
                {
                    nx = (float)(nx / len); ny = (float)(ny / len); nz = (float)(nz / len);
                }
                else { nx = 0f; ny = 0f; nz = 1f; }

                faceNormals[tri * 3] = nx;
                faceNormals[tri * 3 + 1] = ny;
                faceNormals[tri * 3 + 2] = nz;
            }

            // Step 2: accumulate face normals per shared rounded position.
            var posToNormal = new Dictionary<string, float[]>(); // {nx,ny,nz,count}
            for (int v = 0; v < vertexCount; v++)
            {
                string key = Key(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
                int triIdx = v / 3;
                float[] acc;
                if (!posToNormal.TryGetValue(key, out acc))
                {
                    acc = new float[4]; // nx,ny,nz,count
                    posToNormal[key] = acc;
                }
                acc[0] += faceNormals[triIdx * 3];
                acc[1] += faceNormals[triIdx * 3 + 1];
                acc[2] += faceNormals[triIdx * 3 + 2];
                acc[3] += 1f;
            }

            // Step 3: normalize accumulated normals.
            foreach (var acc in posToNormal.Values)
            {
                double len = System.Math.Sqrt(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]);
                if (len > 0.0001)
                {
                    acc[0] = (float)(acc[0] / len);
                    acc[1] = (float)(acc[1] / len);
                    acc[2] = (float)(acc[2] / len);
                }
                else { acc[0] = 0f; acc[1] = 0f; acc[2] = 1f; }
            }

            // Step 4: assign averaged normals back to each vertex.
            for (int v = 0; v < vertexCount; v++)
            {
                string key = Key(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
                float[] acc = posToNormal[key];
                normals[v * 3] = acc[0];
                normals[v * 3 + 1] = acc[1];
                normals[v * 3 + 2] = acc[2];
            }
        }

        // Position key: round to 1e-4 (reference `Math.round(v*10000)/10000`).
        private static string Key(float x, float y, float z)
        {
            return Round(x) + "," + Round(y) + "," + Round(z);
        }

        private static string Round(float v)
        {
            double r = System.Math.Round(v * 10000.0, System.MidpointRounding.AwayFromZero) / 10000.0;
            // JS template literal stringifies a number with minimal digits; we only need
            // a STABLE key, so any consistent invariant format suffices for grouping.
            return r.ToString("R", CultureInfo.InvariantCulture);
        }

        private static int ParseIndex(string[] idx, int i)
        {
            if (i >= idx.Length) return -1;
            int n;
            if (int.TryParse(idx[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out n))
                return n - 1; // 1-based -> 0-based (negative result fails >=0 guard)
            return -1;
        }

        private static float ParseF(string[] parts, int i)
        {
            if (i >= parts.Length) return 0f;
            float f;
            if (float.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out f))
                return f;
            return 0f; // matches JS `parseFloat(...) || 0`
        }

        // Equivalent of JS split(/\s+/) on an already-trimmed line.
        private static string[] SplitWhitespace(string line)
        {
            return line.Split(new char[] { ' ', '\t', '\r', '\f', '\v' },
                System.StringSplitOptions.RemoveEmptyEntries);
        }

        // packMeshDataForTextures — pack de-indexed vertex data into 4-channel
        // texture-sized float arrays (one texel per vertex), reference obj-parser.js.
        //   positionData: RGBA32F xyz, w=1 valid (w=0 for unused texels).
        //   normalData:   RGBA xyz, w=0.
        //   uvData:       RGBA uv, zw=0.
        public static void PackForTextures(NMMeshArrays mesh, int texWidth, int texHeight,
            out float[] positionData, out float[] normalData, out float[] uvData,
            out int usedVertices)
        {
            int pixelCount = texWidth * texHeight;
            int maxVertices = pixelCount;
            int vertexCount = mesh.Positions != null ? mesh.Positions.Length / 3 : 0;
            usedVertices = vertexCount < maxVertices ? vertexCount : maxVertices;

            positionData = new float[pixelCount * 4];
            normalData = new float[pixelCount * 4];
            uvData = new float[pixelCount * 4];

            for (int i = 0; i < usedVertices; i++)
            {
                int pi = i * 4, vi3 = i * 3, vi2 = i * 2;
                positionData[pi] = mesh.Positions[vi3];
                positionData[pi + 1] = mesh.Positions[vi3 + 1];
                positionData[pi + 2] = mesh.Positions[vi3 + 2];
                positionData[pi + 3] = 1f; // valid vertex

                normalData[pi] = mesh.Normals[vi3];
                normalData[pi + 1] = mesh.Normals[vi3 + 1];
                normalData[pi + 2] = mesh.Normals[vi3 + 2];
                normalData[pi + 3] = 0f;

                uvData[pi] = mesh.Uvs[vi2];
                uvData[pi + 1] = mesh.Uvs[vi2 + 1];
                uvData[pi + 2] = 0f;
                uvData[pi + 3] = 0f;
            }
            // Remaining texels already default to 0 (w=0 => invalid vertex).
        }
    }
}
