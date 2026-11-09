import { RiderProfileCard } from "@cadencia/coach/RiderProfile/RiderProfileCard.view";
import { describe, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import * as Scene from "foldkit/scene";
import { LiveProfile, Model } from "../src/model.ts";
import { AppRoute } from "../src/route.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { signedIn } from "./fixture.ts";

describe("the rider profile", () => {
  const card = Schema.decodeUnknownSync(RiderProfileCard.State)({
    report: {
      riderType: "puncheur",
      confidence: "moderate",
      headline: "Short climbs are your terrain",
      summary: "You attack the steep, short ramps.",
      strengths: ["Repeated efforts over 5 minutes"],
      development: ["Pacing long climbs"],
      evidence: [],
      caveats: ["Few races in the record"],
      oldest: "2026-05-01",
      newest: "2026-11-01",
      rideCount: 84,
    },
    model: "gpt-5.5",
    dismissedFtp: null,
  });
  const onProfile = (profile: typeof RiderProfileCard.State.Type | null): Model => ({
    ...signedIn,
    route: AppRoute.Profile(),
    profile: LiveProfile.Success({ data: Option.fromNullishOr(profile) }),
  });

  it("shows the whole report as Cadencia for iPhone does, in Spanish, leaving out empty lists", () =>
    Scene.scene(
      { update, view },
      Scene.given(onProfile(card)),
      Scene.expect(Scene.text("Especialista en repechos")).toExist(),
      Scene.expect(Scene.text("Patrón emergente · confianza moderada")).toExist(),
      Scene.expect(Scene.text("Short climbs are your terrain")).toExist(),
      Scene.expect(Scene.text("Lo que muestra tu historial")).toExist(),
      Scene.expect(Scene.text("Dónde destacas")).toExist(),
      Scene.expect(Scene.text("Repeated efforts over 5 minutes")).toExist(),
      Scene.expect(Scene.text("Oportunidades para mejorar")).toExist(),
      Scene.expect(Scene.text("Lo que falta por conocer")).toExist(),
      Scene.expect(Scene.text("La evidencia")).not.toExist(),
      Scene.expect(Scene.text("84 salidas · 2026-05-01 → 2026-11-01 · gpt-5.5")).toExist(),
    ));

  it("points to the iPhone when there is no report yet", () =>
    Scene.scene(
      { update, view },
      Scene.given(onProfile(null)),
      Scene.expect(Scene.text("Se genera con la IA desde Cadencia para iPhone.")).toExist(),
    ));
});
