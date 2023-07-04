/* global BROWSER_RUNTIME */

let script;
if (typeof BROWSER_RUNTIME != "undefined" && BROWSER_RUNTIME) {
  script = require("Scripts/always-succeeds-v2.plutus");
} else {
  const fs = await import("fs");
  script = fs.readFileSync(
    new URL("../../fixtures/scripts/always-succeeds-v2.plutus", import.meta.url),
    "utf8"
  );
}

export { script as alwaysSucceedsV2 };
