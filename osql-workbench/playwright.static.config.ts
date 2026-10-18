import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir:"test/browser",timeout:120_000,expect:{timeout:60_000},workers:1,
  use:{baseURL:"http://127.0.0.1:5175/osql-workbench/dist/",browserName:"chromium",headless:true},
  webServer:{command:"python3 -m http.server 5175 --bind 127.0.0.1 --directory ..",url:"http://127.0.0.1:5175/osql-workbench/dist/",reuseExistingServer:false},
});
