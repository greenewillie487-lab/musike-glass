import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  testMatch: "**/*.spec.ts",
  use: { baseURL: "http://127.0.0.1:5187", viewport: { width: 390, height: 844 }, reducedMotion: "reduce", trace: "retain-on-failure" },
  webServer: { command: "pnpm dev --port 5187", url: "http://127.0.0.1:5187", reuseExistingServer: !process.env.CI },
});
