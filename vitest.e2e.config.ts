// SPDX-License-Identifier: Apache-2.0

// E2E suite against a running gateway (`mise run e2e`). `mise run test` runs
// only the unit tests from vitest.config.ts.
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['e2e/**/*.e2e.test.ts'],
    environment: 'node',
    // Sandbox creation includes image pulls on a fresh host.
    testTimeout: 360_000,
    hookTimeout: 360_000,
  },
});
