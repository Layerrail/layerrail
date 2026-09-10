import React, { Component, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { ThinkingOrb } from "thinking-orbs";
import { BorderBeam } from "border-beam";
import { MetalFx, setBendConfig } from "metal-fx";
import { setupPlayground } from "./controller.js";

// Effects are decorative islands. The form and response remain usable if a
// browser cannot render a canvas or shader; they never own the interactive DOM.
class EffectBoundary extends Component {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() { return this.state.failed ? null : this.props.children; }
}

function useAnimationAllowed() {
  const query = window.matchMedia("(prefers-reduced-motion: reduce)");
  const [allowed, setAllowed] = useState(!query.matches && !document.hidden);
  useEffect(() => {
    const update = () => setAllowed(!query.matches && !document.hidden);
    query.addEventListener("change", update);
    document.addEventListener("visibilitychange", update);
    return () => {
      query.removeEventListener("change", update);
      document.removeEventListener("visibilitychange", update);
    };
  }, []);
  return allowed;
}

function ComposerBeam({ active }) {
  const animate = useAnimationAllowed();
  return <BorderBeam theme="light" colorVariant="ocean" borderRadius={17} duration={5} strength={0.7} active={active && animate} style={{ width: "100%", height: "100%" }}>
    <div className="playground-effect-surface" />
  </BorderBeam>;
}

function SendMetal({ active }) {
  const animate = useAnimationAllowed();
  // Static CSS chrome remains visible in reduced-motion mode and without WebGL.
  if (!animate) return null;
  return <MetalFx theme="dark" preset="chromatic" strength={0.65} borderRadius={10} normalizeHostStyles={false} paused={!active} style={{ width: "100%", height: "100%" }}>
    <div className="playground-effect-surface" />
  </MetalFx>;
}

function createEffects() {
  const roots = new Map();
  const render = (element, component) => {
    if (!element) return;
    if (!roots.has(element)) roots.set(element, createRoot(element));
    roots.get(element).render(<EffectBoundary>{component}</EffectBoundary>);
  };
  const remove = (element) => {
    if (!element || !roots.has(element)) return;
    roots.get(element).unmount();
    roots.delete(element);
  };
  setBendConfig({ enabled: false });
  const composer = document.getElementById("inference_composer");
  const beam = document.getElementById("inference_composer_effect");
  const metal = document.getElementById("inference_send_effect");
  let busy = false;
  let focused = false;
  const update = () => {
    render(beam, <ComposerBeam active={busy || focused} />);
    render(metal, <SendMetal active={busy || focused} />);
  };
  composer.addEventListener("focusin", () => { focused = true; update(); });
  composer.addEventListener("focusout", (event) => {
    focused = composer.contains(event.relatedTarget);
    update();
  });
  update();
  return {
    orb(element, state) {
      if (!state) return remove(element);
      render(element, <ThinkingOrb state={state} size={64} theme="light" aria-hidden="true" />);
    },
    busy(value) { busy = value; update(); },
    clear() { for (const element of [...roots.keys()]) remove(element); }
  };
}

$(function () {
  if (!document.getElementById("inference_playground")) return;
  const effects = createEffects();
  setupPlayground(effects);
  window.addEventListener("pagehide", (event) => { if (!event.persisted) effects.clear(); });
});
