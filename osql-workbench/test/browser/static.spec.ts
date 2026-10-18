import { expect, test } from "@playwright/test";
import { spawnSync } from "node:child_process";
import { exampleOntology } from "../../client/example";

test.beforeEach(async ({ context }) => {
  await context.route("**/api/**", route => route.abort());
});
test("Haskell WASM compiles the same schema as native Haskell", async ({ page }) => {
  const native = spawnSync(process.env.NATIVE_WORKBENCH_RUNTIME!, [], { input: JSON.stringify({operation:"compile",root:"Root",source:exampleOntology}),encoding:"utf8" });
  expect(native.status, native.stderr).toBe(0);
  const reference = JSON.parse(native.stdout).value;
  await page.goto("./");
  await page.getByRole("button", {name:"Compile",exact:true}).click();
  await expect(page.locator(".table-block")).toHaveCount(reference.tables.length);
  for (const table of reference.tables) await expect(page.locator(".table-block").filter({hasText:table.name})).toHaveCount(1);
});
test("static subpath: compile, generate, inspect and select through PGlite", async ({ page }) => {
  await page.goto("./");
  await page.getByRole("button", {name:"Compile",exact:true}).click();
  await expect(page.locator(".table-block")).toHaveCount(3);
  await page.getByRole("button", {name:/02.*Data/}).click();
  await page.getByLabel("Number of records").fill("2");
  await page.getByRole("button", {name:"Generate 2",exact:true}).click();
  await expect(page.locator("tbody tr")).toHaveCount(2);
  await page.getByRole("button", {name:/03.*Selector/}).click();
  await page.getByRole("button", {name:"Run",exact:true}).click();
  const result = page.getByLabel("NDJSON result");
  await expect(result).toBeVisible();
  const rows = (await result.innerText()).trim().split("\n").map(row=>JSON.parse(row));
  expect(rows).toHaveLength(2);
  expect(rows[0]).toHaveProperty("mentor");
  await page.getByLabel("OSQL selector").fill("9007199254740993.123456789");
  await page.getByRole("button", {name:"Run",exact:true}).click();
  await expect(result).toHaveText("9007199254740993.123456789\n");
  await page.getByLabel("OSQL selector").fill('"héllo 😀"');
  await page.getByRole("button", {name:"Run",exact:true}).click();
  await expect(result).toContainText("héllo 😀");
  await page.getByLabel("OSQL selector").fill("root.doesNotExist");
  await page.getByRole("button", {name:"Run",exact:true}).click();
  await expect(page.getByRole("alert")).toBeVisible();
});
