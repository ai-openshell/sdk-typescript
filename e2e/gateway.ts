// SPDX-License-Identifier: Apache-2.0

// Shared setup for the E2E suite. The suite runs against the gateway named in
// OPENSHELL_GATEWAY, registered under $XDG_CONFIG_HOME/openshell/gateways, for
// example the one scripts/e2e/start-gateway.sh registers as "e2e". Without
// OPENSHELL_GATEWAY every test is skipped.

import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { ConnectOptions, SandboxClient } from '../src/index.js';

export const gatewayName = process.env.OPENSHELL_GATEWAY ?? '';

/** Seconds to wait for a sandbox to become ready, including image pulls. */
export const READY_TIMEOUT_SECS = 300;
/** Seconds to wait for a deleted sandbox to disappear. */
export const DELETE_TIMEOUT_SECS = 120;

interface GatewayMetadata {
  gateway_endpoint: string;
}

/** Connection options for the registered gateway, with mTLS files when it uses https. */
export function connectOptions(): ConnectOptions {
  const configHome = process.env.XDG_CONFIG_HOME || join(homedir(), '.config');
  const dir = join(configHome, 'openshell', 'gateways', gatewayName);
  const metadata = JSON.parse(readFileSync(join(dir, 'metadata.json'), 'utf8')) as GatewayMetadata;
  const gateway = metadata.gateway_endpoint;
  if (!gateway.startsWith('https:')) return { gateway };
  return {
    gateway,
    caCert: readFileSync(join(dir, 'mtls', 'ca.crt')),
    clientCert: readFileSync(join(dir, 'mtls', 'tls.crt')),
    clientKey: readFileSync(join(dir, 'mtls', 'tls.key')),
  };
}

/** A sandbox name that is unique per run, so parallel and repeated runs don't collide. */
export function uniqueName(prefix: string): string {
  return `${prefix}-${randomBytes(4).toString('hex')}`;
}

/** Delete a sandbox and wait until it is gone. Never throws, for use in cleanup. */
export async function cleanup(client: SandboxClient, name: string, workspace?: string): Promise<void> {
  try {
    const result = await client.delete(name, { allowMissing: true, ...(workspace ? { workspace } : {}) });
    await client.waitDeleted(name, DELETE_TIMEOUT_SECS, {
      ...(workspace ? { workspace } : {}),
      ...(result.sandboxId ? { expectedSandboxId: result.sandboxId } : {}),
    });
  } catch (error) {
    console.warn(`cleanup of sandbox ${name} failed: ${error}`);
  }
}

/** Concatenate the stdout and stderr chunks of exec stream events. */
export function text(chunks: Buffer[]): string {
  return Buffer.concat(chunks).toString('utf8');
}
