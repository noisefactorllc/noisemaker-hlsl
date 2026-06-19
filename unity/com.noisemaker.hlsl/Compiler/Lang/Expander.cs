// Expander.cs — Logical Graph (plans) -> Render Graph (passes), a port of
// shaders/src/runtime/expander.js (reference/03) emitting the NORMALIZED schema
// (GRAPH-JSON-SCHEMA.md): passType / namespace / func / progName / defines / ...
//
// SCOPE: builtin _read / _write / _read3d / _write3d, real 2D + 3D effect passes,
// programs, 2D + 3D texture specs (is3D), two-pass arg/uniform processing (incl. the
// volumeSize inheritance guard), inputs/outputs mapping (2D / 3D / geo / agent lanes),
// palette expansion, scoped params, last-pass-to-surface fusion, inline-write dedupe,
// final blit, render surface resolution. Subchain markers + DSL loops implemented.
//
// PARITY-CRITICAL behaviors replicated:
//  - compile-time defines: globals are SORTED by name; suffix is sorted entries joined
//    `__K_V`; value stringified like JS String(v) (reference/03 §4.5 hazard 3).
//  - ALL programs get the nodeId prefix; per-program uniformLayouts take precedence.
//  - colorMode first-pass / non-surface second-pass arg ordering (reference/03 §4.8).
//  - inputs resolution order (reference/03 §5.1); outputs incl. last-pass fusion (§5.3).
//  - 0 vs missing distinction; insertion order preserved (reference/03 §9 hazards 4/5).
//
// Pure C#, no UnityEngine. Emits into the Graph.RenderGraph model.

using System;
using System.Collections.Generic;
using System.Globalization;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl.Compiler
{
    public sealed class ExpandResult
    {
        public List<Pass> Passes { get; } = new List<Pass>();
        public List<string> Errors { get; } = new List<string>();
        public OrderedMap<string, Program> Programs { get; } = new OrderedMap<string, Program>();
        public OrderedMap<string, TextureSpec> TextureSpecs { get; } = new OrderedMap<string, TextureSpec>();
        public string RenderSurface { get; set; }
    }

    public sealed class Expander
    {
        private static readonly System.Text.RegularExpressions.Regex SurfaceRefPattern =
            new System.Text.RegularExpressions.Regex("^(?:o|vol|geo|xyz|vel|rgba)[0-7]$");

        private readonly EffectRegistry _reg;
        private readonly List<Plan> _plans;
        private readonly string _render;

        private readonly ExpandResult _result = new ExpandResult();
        private readonly Dictionary<string, string> _textureMap = new Dictionary<string, string>();
        private string _lastWrittenSurface;
        private bool _blitRegistered;

        // DSL LOOPS: active subchain-loop bracket state. While inside an
        // `iterations:N` subchain, every effect/blit pass emitted is tagged with the
        // current loop group + iteration count so the runtime can re-run the bracket.
        private int _loopGroupCounter;        // monotonic; 0 reserved for "no loop"
        private int _activeLoopGroupId;       // 0 when not inside an iterated bracket
        private int _activeLoopIterations;    // iteration count for the active bracket

        // PARTICLE PIPELINE (reference/03 §4.4 step 1, §6.1). Set to the nodeId of the
        // effect that CREATES particle state (textures.global_xyz, i.e. pointsEmit);
        // particle textures (global_xyz/vel/rgba/points_trail/life_data) are scoped by
        // this id so multiple particle pipelines in one program don't collide. null when
        // no particle pipeline is active. Reset per chain.
        private string _currentParticlePipelineId;
        private string _currentInputXyz;   // agent-state cursors (reference/03 §4.10)
        private string _currentInputVel;
        private string _currentInputRgba;
        // 3D / geo pipeline cursors (reference/03 §4.1/§4.10; synth3d/filter3d subsystem).
        // currentInput3d is the live volume virtualTexId (e.g. global_vol0 or a node's
        // volumeCache); currentInputGeo is the live geometry-buffer virtualTexId. Reset per chain.
        private string _currentInput3d;
        private string _currentInputGeo;

        private Expander(List<Plan> plans, string render, EffectRegistry reg)
        {
            _plans = plans;
            _render = render;
            _reg = reg;
        }

        public static ExpandResult Expand(ValidateResult validated, EffectRegistry reg)
        {
            return new Expander(validated.Plans, validated.Render, reg).Run();
        }

        private ExpandResult Run()
        {
            for (int planIndex = 0; planIndex < _plans.Count; planIndex++)
                ExpandPlan(_plans[planIndex], planIndex);

            if (_render != null) _result.RenderSurface = _render;
            else if (_lastWrittenSurface != null) _result.RenderSurface = _lastWrittenSurface;
            else
            {
                _result.Errors.Add("No render surface specified and no write() found - add render(oN) or write(oN)");
                _result.RenderSurface = null;
            }
            return _result;
        }

        private void ExpandPlan(Plan plan, int planIndex)
        {
            string currentInput = null;
            SurfaceRef lastInlineWriteTarget = null;
            var pipelineUniforms = new OrderedMap<string, UniformValue>();
            string chainScopeId = "chain_" + planIndex;
            // A particle pipeline is scoped to its chain (begins with pointsEmit here).
            _currentParticlePipelineId = null;
            _currentInputXyz = _currentInputVel = _currentInputRgba = null;
            _currentInput3d = _currentInputGeo = null;

            for (int stepPos = 0; stepPos < plan.Chain.Count; stepPos++)
            {
                Step step = plan.Chain[stepPos];

                if (step.Builtin && step.Op == "_read")
                {
                    ArgValue tex = step.Args.Get("tex");
                    if (tex != null && tex.Kind == ArgKind.Surface && tex.Surface.Kind == "output")
                        currentInput = "global_" + tex.Surface.Name;
                    string nodeIdR = "node_" + step.Temp;
                    if (currentInput != null) _textureMap[nodeIdR + "_out"] = currentInput;
                    continue;
                }
                // _read3d (reference/03 §4.1; expander.js lines 162-185). Two-arg starter:
                // sets the 3D + geo cursors from the named vol/geo surfaces (VolRef/GeoRef →
                // global_<name>; plain name passes through) and registers _out3d/_outGeo so a
                // step.from can pick them up.
                if (step.Builtin && step.Op == "_read3d")
                {
                    ArgValue tex3d = step.Args.Get("tex3d");
                    ArgValue geo = step.Args.Get("geo");
                    if (tex3d != null && tex3d.Kind == ArgKind.Surface)
                    {
                        SurfaceRef s = tex3d.Surface;
                        _currentInput3d = s.Kind == "vol" ? "global_" + s.Name : s.Name;
                    }
                    if (geo != null && geo.Kind == ArgKind.Surface)
                    {
                        SurfaceRef s = geo.Surface;
                        _currentInputGeo = s.Kind == "geo" ? "global_" + s.Name : s.Name;
                    }
                    string nodeId3 = "node_" + step.Temp;
                    if (_currentInput3d != null) _textureMap[nodeId3 + "_out3d"] = _currentInput3d;
                    if (_currentInputGeo != null) _textureMap[nodeId3 + "_outGeo"] = _currentInputGeo;
                    continue;
                }
                // _write3d (reference/03 §4.1; expander.js lines 233-285). Chainable: blits the
                // live 3D + geo lanes into global_<vol>/global_<geo> (each skipped on name=="none"
                // or already-equal) and passes all three lanes through.
                if (step.Builtin && step.Op == "_write3d")
                {
                    ArgValue tex3d = step.Args.Get("tex3d");
                    ArgValue geo = step.Args.Get("geo");
                    string nodeIdW3 = "node_" + step.Temp;
                    if (tex3d != null && tex3d.Kind == ArgKind.Surface && tex3d.Surface.Name != "none" && _currentInput3d != null)
                    {
                        string targetVol = "global_" + tex3d.Surface.Name;
                        if (_currentInput3d != targetVol)
                        {
                            var blit = NewBlit(nodeIdW3 + "_write3d_vol_blit", _currentInput3d, targetVol, nodeIdW3, step.Temp);
                            _result.Passes.Add(blit);
                            EnsureBlitProgram();
                        }
                    }
                    if (geo != null && geo.Kind == ArgKind.Surface && geo.Surface.Name != "none" && _currentInputGeo != null)
                    {
                        string targetGeo = "global_" + geo.Surface.Name;
                        if (_currentInputGeo != targetGeo)
                        {
                            var blit = NewBlit(nodeIdW3 + "_write3d_geo_blit", _currentInputGeo, targetGeo, nodeIdW3, step.Temp);
                            _result.Passes.Add(blit);
                        }
                    }
                    if (currentInput != null) _textureMap[nodeIdW3 + "_out"] = currentInput;
                    if (_currentInput3d != null) _textureMap[nodeIdW3 + "_out3d"] = _currentInput3d;
                    if (_currentInputGeo != null) _textureMap[nodeIdW3 + "_outGeo"] = _currentInputGeo;
                    continue;
                }
                if (step.Builtin && step.Op == "_write")
                {
                    ArgValue tex = step.Args.Get("tex");
                    if (tex != null && tex.Kind == ArgKind.Surface && currentInput != null)
                    {
                        SurfaceRef s = tex.Surface;
                        if (s.Name != "none")
                        {
                            string target = "global_" + s.Name;
                            if (currentInput != target)
                            {
                                string nodeIdW = "node_" + step.Temp;
                                var blit = NewBlit(nodeIdW + "_write_blit", currentInput, target, nodeIdW, step.Temp);
                                _result.Passes.Add(blit);
                                EnsureBlitProgram();
                                _lastWrittenSurface = s.Name;
                                lastInlineWriteTarget = new SurfaceRef { Kind = s.Kind, Name = s.Name };
                            }
                        }
                        _textureMap["node_" + step.Temp + "_out"] = currentInput;
                    }
                    continue;
                }
                // Subchain markers are passthrough metadata nodes (reference/03 expander
                // lines 288-318 registerPassthrough): they emit no pass, only keep the
                // texture cursor continuous. DSL LOOPS: a begin marker carrying
                // `iterations > 1` opens an iterated bracket; every pass emitted until the
                // matching end marker is tagged with the loop group (see TagLoop in
                // ExpandPasses / NewBlit call sites). The end marker closes it.
                if (step.Builtin && step.Op == "_subchain_begin")
                {
                    if (currentInput != null) _textureMap["node_" + step.Temp + "_out"] = currentInput;
                    ArgValue iters = step.Args.Get("iterations");
                    if (iters != null && iters.Kind == ArgKind.Number && iters.Number > 1)
                    {
                        _activeLoopGroupId = ++_loopGroupCounter;
                        _activeLoopIterations = (int)System.Math.Floor(iters.Number);
                    }
                    continue;
                }
                if (step.Builtin && step.Op == "_subchain_end")
                {
                    if (currentInput != null) _textureMap["node_" + step.Temp + "_out"] = currentInput;
                    ArgValue iters = step.Args.Get("iterations");
                    if (iters != null && iters.Kind == ArgKind.Number && iters.Number > 1)
                    {
                        _activeLoopGroupId = 0;
                        _activeLoopIterations = 0;
                    }
                    continue;
                }

                lastInlineWriteTarget = null;

                if (step.Args.Has("_skip") && step.Args.Get("_skip").Kind == ArgKind.Bool && step.Args.Get("_skip").Bool)
                {
                    string nodeIdS = "node_" + step.Temp;
                    if (currentInput != null) _textureMap[nodeIdS + "_out"] = currentInput;
                    continue;
                }

                string effectName = step.Op;
                EffectDefinition effectDef = _reg.GetEffect(effectName);
                if (effectDef == null) { _result.Errors.Add("Effect '" + effectName + "' not found"); continue; }

                string nodeId = "node_" + step.Temp;
                var scopedParamMap = new OrderedMap<string, string>();

                // §4.4 step 1: particle-pipeline scope detection. An effect that defines
                // global_xyz state (pointsEmit) STARTS a new particle pipeline; its state
                // textures (and those of downstream flow/physical/pointsRender in the same
                // chain) are scoped by this nodeId. Reset the agent-state cursors.
                if (effectDef.Textures != null && effectDef.Textures.Kind == JsonKind.Object &&
                    effectDef.Textures.Has("global_xyz"))
                {
                    _currentParticlePipelineId = nodeId;
                    _currentInputXyz = _currentInputVel = _currentInputRgba = null;
                }

                // --- compile-time defines (reference/03 §4.5) ---
                var defines = new OrderedMap<string, int>();
                string defineSuffix = BuildDefines(effectDef, step, defines, out var rawDefineValues);

                // --- program collection (reference/03 §4.6) ---
                CollectPrograms(effectDef, nodeId, defineSuffix, defines, rawDefineValues);

                // --- texture-spec collection 2D (reference/03 §6) ---
                CollectTextures(effectDef, nodeId, chainScopeId, scopedParamMap);
                CollectTextures3d(effectDef, nodeId, chainScopeId);

                // --- resolve input cursor ---
                if (step.From.HasValue)
                {
                    string key = "node_" + step.From.Value + "_out";
                    currentInput = _textureMap.TryGetValue(key, out string v) ? v : null;
                }

                // --- globals -> pipelineUniforms defaults + colorMode (reference/03 §4.7) ---
                ApplyGlobalDefaults(effectDef, step, pipelineUniforms);

                // --- args two passes (reference/03 §4.8) ---
                var colorModeControlled = new HashSet<string>();
                ArgsFirstPass(effectDef, step, pipelineUniforms, colorModeControlled);
                ArgsSecondPass(effectDef, step, pipelineUniforms, colorModeControlled, currentInput3dPresent: _currentInput3d != null);

                // --- per-pass expansion (reference/03 §4.9) ---
                ExpandPasses(effectDef, step, nodeId, defineSuffix, defines, plan, pipelineUniforms, scopedParamMap,
                             stepPos, currentInput, chainScopeId);

                // --- cursor update (reference/03 §4.10, 2D only in scope) ---
                currentInput = _textureMap.TryGetValue(nodeId + "_out", out string cur) ? cur : null;
                if (effectDef.OutputTex != null && currentInput == null)
                {
                    string internalTex = effectDef.OutputTex;
                    if (internalTex == "inputTex")
                    {
                        if (step.From.HasValue)
                        {
                            string prev = "node_" + step.From.Value + "_out";
                            if (_textureMap.TryGetValue(prev, out string prevOut))
                            {
                                _textureMap[nodeId + "_out"] = prevOut;
                                currentInput = prevOut;
                            }
                        }
                    }
                    else
                    {
                        string vtid = internalTex.StartsWith("global_")
                            ? ScopeChainTex(internalTex, chainScopeId) : nodeId + "_" + internalTex;
                        _textureMap[nodeId + "_out"] = vtid;
                        currentInput = vtid;
                    }
                }
                // §4.10: 3D cursor update from this node's pass output (expander.js 1031-1035).
                // Note: geo has NO `_outGeo` cursor pickup here — currentInputGeo only updates via
                // the explicit outputGeo declaration below (matches expander.js verbatim).
                if (_textureMap.TryGetValue(nodeId + "_out3d", out string oTex3d)) _currentInput3d = oTex3d;
                // §4.10: agent-state cursors update from this node's pass outputs.
                if (_textureMap.TryGetValue(nodeId + "_outXyz", out string oXyz)) _currentInputXyz = oXyz;
                if (_textureMap.TryGetValue(nodeId + "_outVel", out string oVel)) _currentInputVel = oVel;
                if (_textureMap.TryGetValue(nodeId + "_outRgba", out string oRgba)) _currentInputRgba = oRgba;
                // §4.10: effect-level agent-state passthrough declarations (only when a pass
                // did not already produce the corresponding _out*).
                ApplyAgentPassthrough(effectDef.OutputXyz, nodeId + "_outXyz", nodeId, chainScopeId, "inputXyz", ref _currentInputXyz);
                ApplyAgentPassthrough(effectDef.OutputVel, nodeId + "_outVel", nodeId, chainScopeId, "inputVel", ref _currentInputVel);
                ApplyAgentPassthrough(effectDef.OutputRgba, nodeId + "_outRgba", nodeId, chainScopeId, "inputRgba", ref _currentInputRgba);
                // §4.10: effect-level 3D output passthrough (expander.js 1050-1072). Only when a
                // pass did not already produce _out3d. "inputTex3d" reuses the live 3D cursor;
                // else global_→chain-scope, else node-local.
                if (effectDef.OutputTex3d != null && !_textureMap.ContainsKey(nodeId + "_out3d"))
                {
                    string internalTex = effectDef.OutputTex3d;
                    if (internalTex == "inputTex3d")
                    {
                        if (_currentInput3d != null) _textureMap[nodeId + "_out3d"] = _currentInput3d;
                    }
                    else
                    {
                        string vtid = internalTex.StartsWith("global_")
                            ? ScopeChainTex(internalTex, chainScopeId) : nodeId + "_" + internalTex;
                        _textureMap[nodeId + "_out3d"] = vtid;
                        _currentInput3d = vtid;
                    }
                }
                // §4.10: effect-level geo passthrough (expander.js 1074-1089). "inputGeo" reuses
                // the live geo cursor; else node-scope ONLY (no global_ handling, per reference).
                if (effectDef.OutputGeo != null)
                {
                    string geoTex = effectDef.OutputGeo;
                    if (geoTex == "inputGeo")
                    {
                        if (_currentInputGeo != null) _textureMap[nodeId + "_outGeo"] = _currentInputGeo;
                    }
                    else
                    {
                        string vgid = nodeId + "_" + geoTex;
                        _textureMap[nodeId + "_outGeo"] = vgid;
                        _currentInputGeo = vgid;
                    }
                }
            }

            // --- final chain output (reference/03 §4.11) ---
            if (plan.Write != null && currentInput != null)
            {
                string outName = plan.Write.Name;
                _lastWrittenSurface = outName;
                bool alreadyWritten = lastInlineWriteTarget != null &&
                    lastInlineWriteTarget.Kind == "output" && lastInlineWriteTarget.Name == outName;
                if (alreadyWritten) return;
                string target = "global_" + outName;
                if (currentInput != target)
                {
                    var blit = NewBlit("final_blit_" + outName, currentInput, target, null, null);
                    _result.Passes.Add(blit);
                    EnsureBlitProgram();
                }
            }
        }

        // --- defines (reference/03 §4.5) ------------------------------------

        private string BuildDefines(EffectDefinition effectDef, Step step, OrderedMap<string, int> defines,
                                    out Dictionary<string, double> rawValues)
        {
            rawValues = new Dictionary<string, double>();
            var pairs = new List<KeyValuePair<string, double>>();
            if (effectDef.Globals != null && effectDef.Globals.Kind == JsonKind.Object)
            {
                var names = new List<string>();
                foreach (var kv in effectDef.Globals.AsObject) names.Add(kv.Key);
                names.Sort(StringComparer.Ordinal); // SORTED — deterministic
                foreach (string globalName in names)
                {
                    JsonValue def = effectDef.Globals.Get(globalName);
                    string defineName = StrOf(def, "define");
                    if (defineName == null) continue;
                    string type = StrOf(def, "type");
                    // value = default, overridden by step.args[globalName]
                    double? value = NumDefault(def);
                    if (step.Args.Has(globalName))
                    {
                        ArgValue av = step.Args.Get(globalName);
                        if (av != null && av.Kind == ArgKind.Number) value = av.Number;
                        else if (av != null && av.Kind == ArgKind.Bool) value = av.Bool ? 1 : 0;
                    }
                    // member-string default would resolve via enum; numeric/define values in scope.
                    if (value.HasValue)
                    {
                        pairs.Add(new KeyValuePair<string, double>(defineName, value.Value));
                        rawValues[defineName] = value.Value;
                    }
                }
            }
            // suffix uses SORTED entries (reference: Object.entries(compileTimeDefines) sorted).
            pairs.Sort((a, b) => string.CompareOrdinal(a.Key, b.Key));
            var sb = new System.Text.StringBuilder();
            foreach (var p in pairs)
            {
                defines.Add(p.Key, (int)p.Value);
                sb.Append("__").Append(p.Key).Append("_").Append(JsNumberString(p.Value));
            }
            return sb.ToString();
        }

        // --- program collection (reference/03 §4.6) -------------------------

        private void CollectPrograms(EffectDefinition effectDef, string nodeId, string defineSuffix,
                                     OrderedMap<string, int> defines, Dictionary<string, double> rawDefines)
        {
            if (effectDef.Shaders == null || effectDef.Shaders.Kind != JsonKind.Object) return;
            foreach (var kv in effectDef.Shaders.AsObject)
            {
                string progName = kv.Key;
                string uniqueProgName = nodeId + "_" + progName + defineSuffix;
                if (_result.Programs.ContainsKey(uniqueProgName)) continue;
                var prog = new Program { Raw = kv.Value };
                // per-program layout precedence: uniformLayouts[progName] || uniformLayout
                JsonValue layout = null;
                if (effectDef.UniformLayouts != null && effectDef.UniformLayouts.Kind == JsonKind.Object)
                    layout = effectDef.UniformLayouts.Get(progName);
                if (layout == null) layout = effectDef.UniformLayout;
                if (layout != null && layout.Kind == JsonKind.Object)
                    foreach (var l in layout.AsObject)
                        if (l.Value.Kind == JsonKind.Object)
                            prog.UniformLayout.Add(l.Key, new UniformSlot
                            {
                                Slot = (int)NumOr(l.Value, "slot", 0),
                                Components = StrOf(l.Value, "components")
                            });
                foreach (var d in defines) prog.Defines.Add(d.Key, d.Value);
                _result.Programs.Add(uniqueProgName, prog);
            }
        }

        // --- texture specs (reference/03 §6.2 / §6.3) -----------------------

        private void CollectTextures(EffectDefinition effectDef, string nodeId, string chainScopeId,
                                     OrderedMap<string, string> scopedParamMap)
        {
            if (effectDef.Textures == null || effectDef.Textures.Kind != JsonKind.Object) return;
            foreach (var kv in effectDef.Textures.AsObject)
            {
                string texName = kv.Key;
                JsonValue specJson = kv.Value;
                bool isParticle = IsParticleTex(texName);
                bool particleScoped = isParticle && _currentParticlePipelineId != null;

                // §6.1 virtualTexId: particle+active → pipeline-scoped; global_ → chain-scoped;
                // else node-local.
                string virtualTexId;
                if (particleScoped) virtualTexId = texName + "_" + _currentParticlePipelineId;
                else if (texName.StartsWith("global_")) virtualTexId = texName + "_" + chainScopeId;
                else virtualTexId = nodeId + "_" + texName;

                TextureSpec spec = ParseTextureSpec(specJson);
                bool hasParamRef = DimReferencesParam(spec.Width) || DimReferencesParam(spec.Height);
                // §6.3 shouldScopeParams + scope suffix (particle id when the texture is a
                // particle texture, else the chain scope).
                bool shouldScopeParams = particleScoped || (!particleScoped && texName.StartsWith("global_")) ||
                                         (_currentParticlePipelineId != null && !texName.StartsWith("global_")) ||
                                         hasParamRef;
                string scopeSuffix = particleScoped ? _currentParticlePipelineId : chainScopeId;
                if (shouldScopeParams)
                {
                    spec.Width = ScopeDimSpec(spec.Width, scopeSuffix, scopedParamMap);
                    spec.Height = ScopeDimSpec(spec.Height, scopeSuffix, scopedParamMap);
                }
                _result.TextureSpecs.Add(virtualTexId, spec);
            }
        }

        // --- 3D texture specs (reference/03 §4.4 step 4 / §6.2) -------------
        // Same naming convention as 2D: global_ → chain-scoped; else node-local. Each spec is
        // copied with is3D:true (expander.js lines 498-510). No param-scoping here — the
        // reference does not scope textures3d dims (matches expander.js verbatim).
        private void CollectTextures3d(EffectDefinition effectDef, string nodeId, string chainScopeId)
        {
            if (effectDef.Textures3d == null || effectDef.Textures3d.Kind != JsonKind.Object) return;
            foreach (var kv in effectDef.Textures3d.AsObject)
            {
                string texName = kv.Key;
                string virtualTexId = texName.StartsWith("global_")
                    ? ScopeChainTex(texName, chainScopeId) : nodeId + "_" + texName;
                TextureSpec spec = ParseTextureSpec(kv.Value);
                spec.Is3D = true;
                _result.TextureSpecs.Add(virtualTexId, spec);
            }
        }

        // --- globals defaults + colorMode (reference/03 §4.7) ---------------

        private void ApplyGlobalDefaults(EffectDefinition effectDef, Step step, OrderedMap<string, UniformValue> pipe)
        {
            if (effectDef.Globals == null || effectDef.Globals.Kind != JsonKind.Object) return;
            foreach (var kv in effectDef.Globals.AsObject)
            {
                string globalName = kv.Key;
                JsonValue def = kv.Value;
                string uniform = StrOf(def, "uniform");
                JsonValue dflt = def.Get("default");
                if (uniform != null && dflt != null && dflt.Kind != JsonKind.Null)
                {
                    if (!pipe.ContainsKey(uniform))
                    {
                        UniformValue val = ResolveDefaultUniform(def, dflt);
                        if (val != null) pipe.Add(uniform, val);
                    }
                }
                string type = StrOf(def, "type");
                string colorModeUniform = StrOf(def, "colorModeUniform");
                if (type == "surface" && colorModeUniform != null)
                {
                    if (!step.Args.Has(globalName))
                    {
                        bool isNone = dflt != null && dflt.Kind == JsonKind.String && dflt.AsString == "none";
                        pipe.Add(colorModeUniform, UniformValue.Of((double)(isNone ? 0 : 1)));
                    }
                }
            }
        }

        // --- args two passes (reference/03 §4.8) ----------------------------

        private void ArgsFirstPass(EffectDefinition effectDef, Step step, OrderedMap<string, UniformValue> pipe,
                                   HashSet<string> colorModeControlled)
        {
            foreach (string argName in step.Args.Keys)
            {
                ArgValue arg = step.Args.Get(argName);
                if (arg != null && arg.Kind == ArgKind.Surface && IsColorModeSurfaceKind(arg.Surface.Kind))
                {
                    string colorModeUniform = GlobalColorModeUniform(effectDef, argName);
                    if (colorModeUniform != null)
                    {
                        bool isNone = arg.Surface.Name == "none";
                        pipe.Add(colorModeUniform, UniformValue.Of((double)(isNone ? 0 : 1)));
                        colorModeControlled.Add(colorModeUniform);
                    }
                }
            }
        }

        private void ArgsSecondPass(EffectDefinition effectDef, Step step, OrderedMap<string, UniformValue> pipe,
                                    HashSet<string> colorModeControlled, bool currentInput3dPresent)
        {
            foreach (string argName in step.Args.Keys)
            {
                ArgValue arg = step.Args.Get(argName);
                if (arg != null && arg.Kind == ArgKind.Surface && IsColorModeSurfaceKind(arg.Surface.Kind)) continue;
                if (argName == "_skip") continue;
                string uniformName = GlobalUniformName(effectDef, argName) ?? argName;
                if (colorModeControlled.Contains(uniformName)) continue;
                // §4.8 / §9 hazard 9: inherit upstream volumeSize when this effect reads a 3D
                // input — skip writing this effect's own volumeSize arg (expander.js 606-608).
                if (uniformName == "volumeSize" && currentInput3dPresent && pipe.ContainsKey("volumeSize")) continue;
                UniformValue v = ArgToUniform(arg);
                if (v != null) pipe.Add(uniformName, v);
            }
        }

        // --- per-pass expansion (reference/03 §4.9) -------------------------

        private void ExpandPasses(EffectDefinition effectDef, Step step, string nodeId, string defineSuffix,
                                  OrderedMap<string, int> defines,
                                  Plan plan, OrderedMap<string, UniformValue> pipe, OrderedMap<string, string> scopedParamMap,
                                  int stepPos, string currentInput, string chainScopeId)
        {
            if (effectDef.Passes == null || effectDef.Passes.Kind != JsonKind.Array) return;
            List<JsonValue> passDefs = effectDef.Passes.AsArray;

            // define-tagged globals become COMPILE-TIME DEFINES (pass.Defines), not
            // runtime uniforms. Exclude their keys from THIS effect's pass uniforms
            // (reference keeps them in the pipeline for DOWNSTREAM passes, but the
            // defining pass carries them as defines). reference/03 §4.5/§4.9. Without
            // this, pass.Defines is empty so the backend never SetInt()s the define
            // (e.g. NOISE_TYPE/LOOP_OFFSET) and the shader uses its fallback default.
            var defineKeys = new System.Collections.Generic.HashSet<string>();
            if (effectDef.Globals != null && effectDef.Globals.Kind == JsonKind.Object)
                foreach (var gk in effectDef.Globals.AsObject)
                {
                    if (StrOf(gk.Value, "define") == null) continue;
                    defineKeys.Add(gk.Key);
                    string un = StrOf(gk.Value, "uniform");
                    if (un != null) defineKeys.Add(un);
                }
            for (int i = 0; i < passDefs.Count; i++)
            {
                JsonValue passDef = passDefs[i];
                string passId = nodeId + "_pass_" + i;
                string programName = nodeId + "_" + StrOf(passDef, "program") + defineSuffix;

                var pass = new Pass
                {
                    Id = passId,
                    PassType = PassType.Effect,
                    Program = programName,
                    ProgName = StrOf(passDef, "program"),
                    DrawMode = StrOf(passDef, "drawMode"),
                    CountUniform = StrOf(passDef, "countUniform"),
                    EffectKey = step.Op,
                    Func = effectDef.Func ?? step.Op,
                    Namespace = effectDef.Namespace,
                    NodeId = nodeId,
                    StepIndex = step.Temp,
                    // DSL LOOPS: tag with the active iterated-subchain bracket (0 = none).
                    LoopGroupId = _activeLoopGroupId,
                    LoopIterations = _activeLoopGroupId != 0 ? _activeLoopIterations : 0
                };
                // §4.9 step 3 / §9 hazard 9: a 3D consumer pass inherits the upstream volume's
                // size — flag it so the backend skips re-applying a stale local volumeSize
                // (expander.js 666-668). Gated on currentInput3d AND an inherited volumeSize.
                if (_currentInput3d != null && pipe.ContainsKey("volumeSize"))
                    pass.InheritsVolumeSize = true;
                int? drawBuffers = NullableInt(passDef, "drawBuffers");
                if (drawBuffers.HasValue) pass.DrawBuffers = drawBuffers;
                int? count = NullableInt(passDef, "count");
                if (count.HasValue) pass.Count = count;
                JsonValue blend = passDef.Get("blend");
                pass.Blend = blend != null && blend.Kind == JsonKind.Bool && blend.AsBool;
                JsonValue repeat = passDef.Get("repeat");
                if (repeat != null && repeat.Kind == JsonKind.Number) pass.Repeat = Repeat.FromCount((int)repeat.AsNumber);
                else if (repeat != null && repeat.Kind == JsonKind.String) pass.Repeat = Repeat.FromUniform(repeat.AsString);

                // VOLUME-WRITE viewport (synth3d/filter3d atlas passes, reference/04 §10).
                // viewport: { width:<Dim>, height:<Dim> } sets the render region AND the
                // _NM_Resolution override (NMRenderBackend) so NM_FragCoord recovers the
                // atlas pixel -> voxel addressing. Scope-rewrite Dims like texture dims so a
                // chained volumeSize param resolves under the node's chain scope.
                JsonValue viewport = passDef.Get("viewport");
                if (viewport != null && viewport.Kind == JsonKind.Object)
                {
                    JsonValue vw = viewport.Get("width");
                    JsonValue vh = viewport.Get("height");
                    if (vw != null) pass.ViewportWidth = ScopeDimSpec(GraphLoader.ParseDim(vw), chainScopeId, scopedParamMap);
                    if (vh != null) pass.ViewportHeight = ScopeDimSpec(GraphLoader.ParseDim(vh), chainScopeId, scopedParamMap);
                }

                if (StrOf(passDef, "entryPoint") != null || passDef.Has("workgroups") ||
                    passDef.Has("storageBuffers") || passDef.Has("storageTextures"))
                    throw new NotImplementedException("compute/MRT pass fields (entryPoint/workgroups/storage*) are not implemented in the first-cut Expander (reference/03 §2.1).");

                // compile-time defines for this pass (reference/03 §4.5).
                pass.Defines = new OrderedMap<string, int>();
                if (defines != null) foreach (var d in defines) pass.Defines.Add(d.Key, d.Value);

                // pass.uniforms = { ...pipelineUniforms }, minus THIS effect's define-globals
                foreach (var u in pipe) if (!defineKeys.Contains(u.Key)) pass.Uniforms.Add(u.Key, u.Value);

                // defaults fill (reference/03 §4.9 step 5)
                if (effectDef.Globals != null && effectDef.Globals.Kind == JsonKind.Object)
                    foreach (var kv in effectDef.Globals.AsObject)
                    {
                        JsonValue def = kv.Value;
                        string uniform = StrOf(def, "uniform");
                        JsonValue dflt = def.Get("default");
                        if (uniform != null && dflt != null && dflt.Kind != JsonKind.Null
                            && !pass.Uniforms.ContainsKey(uniform) && !defineKeys.Contains(uniform))
                        {
                            UniformValue val = ResolveDefaultUniform(def, dflt);
                            if (val != null) { pass.Uniforms.Add(uniform, val); pipe.Add(uniform, val); }
                        }
                    }

                // uniformSpecs (reference/03 §4.9 step 6)
                if (effectDef.Globals != null && effectDef.Globals.Kind == JsonKind.Object)
                    foreach (var kv in effectDef.Globals.AsObject)
                    {
                        JsonValue def = kv.Value;
                        string uniform = StrOf(def, "uniform") ?? kv.Key;
                        string type = StrOf(def, "type");
                        bool hasChoices = def.Has("choices") && def.Get("choices").Kind == JsonKind.Object;
                        if ((type == "float" || type == "int") && !hasChoices)
                            pass.UniformSpecs.Add(uniform, new UniformSpec
                            {
                                Min = NumOr(def, "min", 0),
                                Max = NumOr(def, "max", 100)
                            });
                    }

                // args -> uniforms (reference/03 §4.9 step 7)
                foreach (string argName in step.Args.Keys)
                {
                    ArgValue arg = step.Args.Get(argName);
                    if (arg != null && arg.Kind == ArgKind.Surface && IsColorModeSurfaceKind(arg.Surface.Kind)) continue;
                    if (argName == "_skip") continue;
                    string uniformName = GlobalUniformName(effectDef, argName) ?? argName;
                    if (IsColorModeControlled(effectDef, uniformName)) continue;
                    // define-tagged globals are COMPILE-TIME defines, never runtime uniforms
                    // (reference/03 §4.5/§4.9). A define-global with no `uniform` field (e.g.
                    // noise `type`→NOISE_TYPE, `loopOffset`→LOOP_OFFSET) must NOT leak here.
                    if (defineKeys.Contains(argName) || defineKeys.Contains(uniformName)) continue;
                    // §9 hazard 9: inherit upstream volumeSize over this effect's local arg
                    // when reading a 3D input (expander.js 743-745).
                    if (uniformName == "volumeSize" && _currentInput3d != null && pipe.ContainsKey("volumeSize")) continue;
                    UniformValue v = ArgToUniform(arg);
                    if (v != null) { pass.Uniforms.Add(uniformName, v); pipe.Add(uniformName, v); }
                }

                // pass-level uniform wiring (reference/03 §4.9 step 8)
                JsonValue passUniforms = passDef.Get("uniforms");
                if (passUniforms != null && passUniforms.Kind == JsonKind.Object)
                    foreach (var kv in passUniforms.AsObject)
                    {
                        string uniformName = kv.Key;
                        string globalRef = kv.Value.Kind == JsonKind.String ? kv.Value.AsString : null;
                        if (pipe.ContainsKey(uniformName)) pass.Uniforms.Add(uniformName, pipe[uniformName]);
                        else if (globalRef != null && pipe.ContainsKey(globalRef)) pass.Uniforms.Add(uniformName, pipe[globalRef]);
                        else if (globalRef != null && effectDef.Globals != null && effectDef.Globals.Kind == JsonKind.Object)
                        {
                            JsonValue gdef = effectDef.Globals.Get(globalRef);
                            if (gdef != null)
                            {
                                JsonValue gd = gdef.Get("default");
                                if (gd != null && gd.Kind != JsonKind.Null)
                                {
                                    UniformValue val = ResolveDefaultUniform(gdef, gd);
                                    if (val != null) pass.Uniforms.Add(uniformName, val);
                                }
                            }
                        }
                    }

                // palette expansion (reference/03 §4.9 step 9)
                ExpandPalettes(effectDef, pass, pipe);

                // inputs (reference/03 §5.1)
                MapInputs(effectDef, passDef, step, nodeId, plan, currentInput, pass, chainScopeId);

                // outputs (reference/03 §5.2 incl. last-pass fusion §5.3)
                MapOutputs(passDef, step, nodeId, plan, i, passDefs.Count, stepPos, pass, chainScopeId);

                // scoped-param propagation (reference/03 §4.9 step 12)
                foreach (var sp in scopedParamMap)
                {
                    if (pass.Uniforms.ContainsKey(sp.Key))
                    {
                        pass.Uniforms.Add(sp.Value, pass.Uniforms[sp.Key]);
                        pipe.Add(sp.Value, pass.Uniforms[sp.Key]);
                    }
                }
                if (scopedParamMap.Count > 0)
                {
                    pass.ScopedParams = new OrderedMap<string, string>();
                    foreach (var sp in scopedParamMap) pass.ScopedParams.Add(sp.Key, sp.Value);
                }

                _result.Passes.Add(pass);
            }
        }

        // --- inputs / outputs mapping (reference/03 §5) ---------------------

        private void MapInputs(EffectDefinition effectDef, JsonValue passDef, Step step, string nodeId,
                               Plan plan, string currentInput, Pass pass, string chainScopeId)
        {
            JsonValue inputs = passDef.Get("inputs");
            if (inputs == null || inputs.Kind != JsonKind.Object) return;
            // currentInput is the live pipeline cursor (set by step.from resolution or an
            // upstream _read), matching expander.js's `currentInput` local (reference/03 §5.1).
            string cur = currentInput;

            foreach (var kv in inputs.AsObject)
            {
                string uniformName = kv.Key;
                string texRef = kv.Value.Kind == JsonKind.String ? kv.Value.AsString : null;
                if (texRef == null) continue;

                bool isPipelineInput = texRef == "inputTex" ||
                    (texRef.StartsWith("o") && IntPrefixOk(texRef));

                if (isPipelineInput) { pass.Inputs.Add(uniformName, cur ?? texRef); }
                // §5.1 step 4: agent-state cursors (particle pipeline).
                else if (texRef == "inputXyz") pass.Inputs.Add(uniformName, _currentInputXyz ?? texRef);
                else if (texRef == "inputVel") pass.Inputs.Add(uniformName, _currentInputVel ?? texRef);
                else if (texRef == "inputRgba") pass.Inputs.Add(uniformName, _currentInputRgba ?? texRef);
                // §5.1 steps 2-3: 3D / geo pipeline inputs (synth3d/filter3d).
                else if (texRef == "inputTex3d") pass.Inputs.Add(uniformName, _currentInput3d ?? texRef);
                else if (texRef == "inputGeo") pass.Inputs.Add(uniformName, _currentInputGeo ?? texRef);
                else if (texRef == "noise") pass.Inputs.Add(uniformName, "global_noise");
                else if (texRef == "midiNoteGrid") pass.Inputs.Add(uniformName, "midiNoteGrid");
                else if (texRef == "feedback" || texRef == "selfTex")
                {
                    if (plan.Write != null)
                    {
                        string outName = plan.Write.Name;
                        string prefix = plan.Write.Kind == "feedback" ? "feedback" : "global";
                        pass.Inputs.Add(uniformName, prefix + "_" + outName);
                    }
                    else pass.Inputs.Add(uniformName, cur ?? "global_inputTex");
                }
                else if (effectDef.ExternalTexture != null && texRef == effectDef.ExternalTexture)
                    pass.Inputs.Add(uniformName, texRef + "_step_" + step.Temp);
                else if (step.Args.Has(texRef))
                {
                    ArgValue arg = step.Args.Get(texRef);
                    if (arg == null) continue; // intentionally unbound
                    if (arg.Kind == ArgKind.Surface)
                    {
                        SurfaceRef s = arg.Surface;
                        if (s.Kind == "temp")
                        {
                            string key = "node_" + s.Index + "_out";
                            pass.Inputs.Add(uniformName, _textureMap.TryGetValue(key, out string tv) ? tv : null);
                        }
                        else
                            pass.Inputs.Add(uniformName, s.Name == "none" ? "none" : "global_" + s.Name);
                    }
                    else if (arg.Kind == ArgKind.String)
                        pass.Inputs.Add(uniformName, ResolveGlobalSurfaceRef(arg.String));
                }
                else if (effectDef.Globals != null && effectDef.Globals.Kind == JsonKind.Object &&
                         GlobalHasDefault(effectDef, texRef, out string defaultVal))
                {
                    if (defaultVal == "none") pass.Inputs.Add(uniformName, "none");
                    else if (defaultVal == "inputTex" || defaultVal == "inputColor") pass.Inputs.Add(uniformName, cur ?? defaultVal);
                    else if (SurfaceRefPattern.IsMatch(defaultVal)) pass.Inputs.Add(uniformName, "global_" + defaultVal);
                    else if (defaultVal.StartsWith("global_")) pass.Inputs.Add(uniformName, ScopeChainTex(defaultVal, chainScopeId));
                    else pass.Inputs.Add(uniformName, defaultVal);
                }
                else if (texRef.StartsWith("global_")) pass.Inputs.Add(uniformName, ScopeChainTex(texRef, chainScopeId));
                else if (texRef == "outputTex") pass.Inputs.Add(uniformName, nodeId + "_out");
                else pass.Inputs.Add(uniformName, nodeId + "_" + texRef);
            }
        }

        private void MapOutputs(JsonValue passDef, Step step, string nodeId, Plan plan, int i, int passCount,
                                int stepPos, Pass pass, string chainScopeId)
        {
            JsonValue outputs = passDef.Get("outputs");
            if (outputs == null || outputs.Kind != JsonKind.Object) return;
            foreach (var kv in outputs.AsObject)
            {
                string attachment = kv.Key;
                string texRef = kv.Value.Kind == JsonKind.String ? kv.Value.AsString : null;
                if (texRef == null) continue;
                string virtualTex;
                if (texRef == "outputTex")
                {
                    bool isLastStep = stepPos == plan.Chain.Count - 1;
                    bool isLastPass = i == passCount - 1;
                    if (isLastStep && isLastPass && plan.Write != null)
                    {
                        string outName = plan.Write.Name;
                        string prefix = plan.Write.Kind == "feedback" ? "feedback" : "global";
                        virtualTex = prefix + "_" + outName;
                        _lastWrittenSurface = outName;
                    }
                    else virtualTex = nodeId + "_out";
                    _textureMap[virtualTex] = virtualTex;
                    _textureMap[nodeId + "_out"] = virtualTex;
                }
                // §5.2: agent-state outputs → node-scoped state textures (registered so the
                // §4.10 cursor update can pick them up).
                else if (texRef == "outputXyz") { virtualTex = nodeId + "_outXyz"; _textureMap[nodeId + "_outXyz"] = virtualTex; }
                else if (texRef == "outputVel") { virtualTex = nodeId + "_outVel"; _textureMap[nodeId + "_outVel"] = virtualTex; }
                else if (texRef == "outputRgba") { virtualTex = nodeId + "_outRgba"; _textureMap[nodeId + "_outRgba"] = virtualTex; }
                // §5.2: agent-state write-back (read-modify-write the live cursor).
                else if (texRef == "inputXyz") virtualTex = _currentInputXyz ?? (nodeId + "_inputXyz");
                else if (texRef == "inputVel") virtualTex = _currentInputVel ?? (nodeId + "_inputVel");
                else if (texRef == "inputRgba") virtualTex = _currentInputRgba ?? (nodeId + "_inputRgba");
                // §5.2: 3D output → node-scoped state texture (registered for the §4.10 cursor).
                else if (texRef == "outputTex3d") { virtualTex = nodeId + "_out3d"; _textureMap[nodeId + "_out3d"] = virtualTex; }
                // §5.2: 3D / geo write-back (read-modify-write the live cursor).
                else if (texRef == "inputTex3d") virtualTex = _currentInput3d ?? (nodeId + "_inputTex3d");
                else if (texRef == "inputGeo") virtualTex = _currentInputGeo ?? (nodeId + "_inputGeo");
                else if (texRef.StartsWith("global_")) virtualTex = ScopeChainTex(texRef, chainScopeId);
                else if (texRef.StartsWith("feedback_")) virtualTex = texRef;
                else virtualTex = nodeId + "_" + texRef;
                pass.Outputs.Add(attachment, virtualTex);
            }
        }

        // --- palette expansion (reference/03 §4.9 step 9 / §7) --------------

        private void ExpandPalettes(EffectDefinition effectDef, Pass pass, OrderedMap<string, UniformValue> pipe)
        {
            if (effectDef.Globals == null || effectDef.Globals.Kind != JsonKind.Object) return;
            foreach (var kv in effectDef.Globals.AsObject)
            {
                JsonValue def = kv.Value;
                if (StrOf(def, "type") != "palette") continue;
                string uniformName = StrOf(def, "uniform") ?? kv.Key;
                if (!pass.Uniforms.ContainsKey(uniformName)) continue;
                UniformValue uv = pass.Uniforms[uniformName];
                if (uv.Kind != UniformValueKind.Number) continue;
                double index = uv.Number;
                List<KeyValuePair<string, double[]>> vecs = PaletteExpansion.ExpandVectors(index);
                if (vecs == null) continue;
                foreach (var v in vecs)
                    if (pass.Uniforms.ContainsKey(v.Key))
                    {
                        UniformValue arr = UniformValue.Of(new List<double>(v.Value));
                        pass.Uniforms.Add(v.Key, arr);
                        pipe.Add(v.Key, arr);
                    }
                int? mode = PaletteExpansion.ExpandMode(index);
                if (mode.HasValue && pass.Uniforms.ContainsKey("paletteMode"))
                {
                    UniformValue mv = UniformValue.Of((double)mode.Value);
                    pass.Uniforms.Add("paletteMode", mv);
                    pipe.Add("paletteMode", mv);
                }
            }
        }

        // --- helpers --------------------------------------------------------

        private Pass NewBlit(string id, string src, string dst, string nodeId, int? stepIndex)
        {
            var p = new Pass
            {
                Id = id,
                PassType = PassType.Blit,
                Program = "blit",
                Func = "blit",
                NodeId = nodeId,
                StepIndex = stepIndex,
                // DSL LOOPS: tag with the active iterated bracket (0 = none). The chain
                // final-blit runs after the bracket closes, so it is naturally untagged.
                LoopGroupId = _activeLoopGroupId,
                LoopIterations = _activeLoopGroupId != 0 ? _activeLoopIterations : 0
            };
            p.Inputs.Add("src", src);
            p.Outputs.Add("color", dst);
            return p;
        }

        // The blit program is registered lazily (reference/03 §2.3); the HLSL loader
        // resolves it by func=="blit" and does not need shader source, so Raw is null.
        private void EnsureBlitProgram()
        {
            if (_blitRegistered) return;
            if (!_result.Programs.ContainsKey("blit"))
                _result.Programs.Add("blit", new Program());
            _blitRegistered = true;
        }

        private static bool IsParticleTex(string name)
        {
            return name == "global_xyz" || name == "global_vel" || name == "global_rgba" ||
                   name == "global_points_trail" || name == "global_life_data";
        }
        private static bool IsColorModeSurfaceKind(string kind)
        {
            return kind == "temp" || kind == "output" || kind == "source" || kind == "feedback" ||
                   kind == "xyz" || kind == "vel" || kind == "rgba";
        }

        private static string GlobalUniformName(EffectDefinition def, string argName)
        {
            if (def.Globals == null || def.Globals.Kind != JsonKind.Object) return null;
            JsonValue g = def.Globals.Get(argName);
            return g != null ? StrOf(g, "uniform") : null;
        }
        private static string GlobalColorModeUniform(EffectDefinition def, string argName)
        {
            if (def.Globals == null || def.Globals.Kind != JsonKind.Object) return null;
            JsonValue g = def.Globals.Get(argName);
            return g != null ? StrOf(g, "colorModeUniform") : null;
        }
        private static bool IsColorModeControlled(EffectDefinition def, string uniformName)
        {
            if (def.Globals == null || def.Globals.Kind != JsonKind.Object) return false;
            foreach (var kv in def.Globals.AsObject)
                if (StrOf(kv.Value, "colorModeUniform") == uniformName) return true;
            return false;
        }
        private static bool GlobalHasDefault(EffectDefinition def, string name, out string defaultVal)
        {
            defaultVal = null;
            JsonValue g = def.Globals.Get(name);
            if (g == null) return false;
            JsonValue d = g.Get("default");
            if (d == null || d.Kind == JsonKind.Null) return false;
            defaultVal = d.Kind == JsonKind.String ? d.AsString : null;
            return defaultVal != null;
        }

        private static UniformValue ArgToUniform(ArgValue arg)
        {
            if (arg == null) return null;
            switch (arg.Kind)
            {
                case ArgKind.Number: return UniformValue.Of(arg.Number);
                case ArgKind.Bool: return UniformValue.Of(arg.Bool);
                case ArgKind.String: return UniformValue.Of(arg.String);
                case ArgKind.NumberArray: return UniformValue.Of(new List<double>(arg.NumberArray));
                case ArgKind.Wrapped:
                    // Automation config (Oscillator/Midi/Audio). The validator resolves
                    // osc() to a JsonValue config (reference/02 §6.11); carry it verbatim
                    // as an Object uniform so the runtime UniformBinder evaluates it
                    // per-frame (reference/04 §10.4). Midi/Audio remain out of scope.
                    if (arg.Wrapped is JsonValue jv) return UniformValue.OfObject(jv);
                    throw new NotImplementedException("non-oscillator automation uniform values are not implemented (reference/03 §1.1).");
                default: return null;
            }
        }

        // Resolve a global's default to a UniformValue; member-string defaults resolve to
        // their enum int (reference/03 §4.7).
        private static UniformValue ResolveDefaultUniform(JsonValue def, JsonValue dflt)
        {
            string type = StrOf(def, "type");
            if (dflt.Kind == JsonKind.Number) return UniformValue.Of(dflt.AsNumber);
            if (dflt.Kind == JsonKind.Bool) return UniformValue.Of(dflt.AsBool);
            if (dflt.Kind == JsonKind.Array)
            {
                var nums = new List<double>();
                bool ok = true;
                foreach (JsonValue e in dflt.AsArray)
                    if (e.Kind == JsonKind.Number) nums.Add(e.AsNumber); else { ok = false; break; }
                if (ok) return UniformValue.Of(nums);
                return UniformValue.OfObject(dflt);
            }
            if (dflt.Kind == JsonKind.String)
            {
                if (type == "member")
                {
                    var path = new List<string>(dflt.AsString.Split('.'));
                    double? resolved = ResolveEnumNumberStatic(path);
                    if (resolved.HasValue) return UniformValue.Of(resolved.Value);
                }
                return UniformValue.Of(dflt.AsString);
            }
            return null;
        }

        // resolveEnum over the std/project enum tree (reference/03 §1 resolveEnum). The
        // expander only walks the enum tree (no symbols), matching expander.js.
        private static double? ResolveEnumNumberStatic(IReadOnlyList<string> path)
        {
            if (path == null || path.Count == 0) return null;
            EnumNode node;
            if (!Enums.TryGetHead(path[0], out node)) return null;
            for (int i = 1; i < path.Count; i++)
            {
                if (node == null || node.HasValue) return null;
                if (!node.Children.TryGet(path[i], out node)) return null;
            }
            return (node != null && node.HasValue) ? (double?)node.Value : null;
        }

        private static string ResolveGlobalSurfaceRef(string name)
        {
            if (name == "none") return "none";
            if (name.StartsWith("global_")) return name;
            if (SurfaceRefPattern.IsMatch(name)) return "global_" + name;
            return name;
        }

        // scopeParticleTex (reference/03 §6.1): a particle texture is scoped by the active
        // particle-pipeline id; if no pipeline is active it is left unchanged (NOT chain-scoped).
        private string ScopeParticleTex(string name)
        {
            if (_currentParticlePipelineId != null && IsParticleTex(name))
                return name + "_" + _currentParticlePipelineId;
            return name;
        }

        // scopeChainTex (reference/03 §6.2): particle scoping takes priority; else global_
        // textures are chain-scoped; else unchanged.
        private string ScopeChainTex(string texName, string chainScopeId)
        {
            if (IsParticleTex(texName)) return ScopeParticleTex(texName);
            if (texName.StartsWith("global_")) return texName + "_" + chainScopeId;
            return texName;
        }

        // §4.10 effect-level agent-state passthrough. `decl` is the effect's
        // outputXyz/Vel/Rgba; `outKey` is `${nodeId}_outXyz` etc. Skips when a pass already
        // produced outKey. `reuseKeyword` (=='inputXyz'...) reuses the live cursor; global_
        // is scope-resolved; else node-local.
        private void ApplyAgentPassthrough(string decl, string outKey, string nodeId, string chainScopeId,
                                           string reuseKeyword, ref string cursor)
        {
            if (decl == null || _textureMap.ContainsKey(outKey)) return;
            string vtid;
            if (decl == reuseKeyword) vtid = cursor;
            else if (decl.StartsWith("global_")) vtid = ScopeChainTex(decl, chainScopeId);
            else vtid = nodeId + "_" + decl;
            if (vtid == null) return;
            _textureMap[outKey] = vtid;
            cursor = vtid;
        }

        private static bool DimReferencesParam(Dim d)
        {
            return d != null && (d.Kind == DimKind.Param || d.Kind == DimKind.ScreenDivide);
        }

        // Rewrite a {param}/{screenDivide} dim to a chain-scoped param name and record it.
        private static Dim ScopeDimSpec(Dim d, string scopeSuffix, OrderedMap<string, string> scopedParamMap)
        {
            if (d == null) return null;
            if (d.Kind == DimKind.Param && d.Param != null)
            {
                string scoped = d.Param + "_" + scopeSuffix;
                scopedParamMap.Add(d.Param, scoped);
                return Dim.FromParam(scoped, d.ParamDefault, d.Multiply, d.Power, d.DefaultValue);
            }
            if (d.Kind == DimKind.ScreenDivide && d.ScreenDivide != null)
            {
                string scoped = d.ScreenDivide + "_" + scopeSuffix;
                scopedParamMap.Add(d.ScreenDivide, scoped);
                return Dim.FromScreenDivide(scoped, d.DefaultValue);
            }
            return d;
        }

        private static bool HasAny(JsonValue obj)
        {
            if (obj == null || obj.Kind != JsonKind.Object) return false;
            foreach (var _ in obj.AsObject) return true;
            return false;
        }

        private static bool IntPrefixOk(string texRef)
        {
            // mirrors !isNaN(parseInt(texRef.slice(1))) — at least one leading digit.
            if (texRef.Length < 2) return false;
            char c = texRef[1];
            return c >= '0' && c <= '9';
        }

        // --- JSON dim / texture parsing (delegates to GraphLoader semantics) ---

        private static TextureSpec ParseTextureSpec(JsonValue s)
        {
            var spec = new TextureSpec
            {
                Width = GraphLoader.ParseDim(s.Get("width")),
                Height = GraphLoader.ParseDim(s.Get("height")),
                Is3D = s.Has("is3D") && s.Get("is3D").Kind == JsonKind.Bool && s.Get("is3D").AsBool,
                Format = StrOf(s, "format")
            };
            JsonValue depth = s.Get("depth");
            if (depth != null && depth.Kind != JsonKind.Null) spec.Depth = GraphLoader.ParseDim(depth);
            // default 'screen' when width/height absent (compiler.js extractTextureSpecs).
            if (spec.Width == null) spec.Width = Dim.FromScreen();
            if (spec.Height == null) spec.Height = Dim.FromScreen();
            return spec;
        }

        private static string StrOf(JsonValue obj, string key)
        {
            if (obj == null) return null;
            JsonValue v = obj.Get(key);
            return (v != null && v.Kind == JsonKind.String) ? v.AsString : null;
        }
        private static double NumOr(JsonValue obj, string key, double fallback)
        {
            JsonValue v = obj.Get(key);
            return (v != null && v.Kind == JsonKind.Number) ? v.AsNumber : fallback;
        }
        private static double? NumDefault(JsonValue def)
        {
            JsonValue d = def.Get("default");
            if (d == null) return null;
            if (d.Kind == JsonKind.Number) return d.AsNumber;
            if (d.Kind == JsonKind.Bool) return d.AsBool ? 1 : 0;
            return null;
        }
        private static int? NullableInt(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            if (v == null || v.Kind != JsonKind.Number) return null;
            return (int)v.AsNumber;
        }

        // JS String(number): integer-valued doubles print without ".0".
        private static string JsNumberString(double v)
        {
            if (v == Math.Floor(v) && !double.IsInfinity(v))
                return ((long)v).ToString(CultureInfo.InvariantCulture);
            return v.ToString("R", CultureInfo.InvariantCulture);
        }
    }
}
