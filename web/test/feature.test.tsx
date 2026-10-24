import { render } from "@testing-library/preact";
import { describe, expect, test } from "vitest";
import { load } from "./load";

const F = load(() => import("../src/components/feature"));

describe("FeatureMissing", () => {
  test("explains the missing feature", () => {
    expect(render(<F.m.FeatureMissing title="Batches aren't available on this server" hint="Upgrade Robin." />).container).toMatchSnapshot();
  });
});
