// SPDX-License-Identifier: Apache-2.0

import { connect as tcpConnect } from 'node:net';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import {
  type ExecInteractiveSessionControl,
  type ExecStreamEvent,
  OpenShellClient,
  SandboxClient,
  SdkError,
} from '../src/index.js';
import { cleanup, connectOptions, gatewayName, READY_TIMEOUT_SECS, text, uniqueName } from './gateway.js';

describe.skipIf(!gatewayName)('gateway', () => {
  test('reports healthy', async () => {
    const client = await OpenShellClient.connect(connectOptions());
    const health = await client.health();
    expect(health.status).toBe('healthy');
    expect(health.version).not.toBe('');
  });
});

describe.skipIf(!gatewayName)('sandbox lifecycle', () => {
  test('creates, finds, and deletes a sandbox', async () => {
    const client = await SandboxClient.connect(connectOptions());
    const name = uniqueName('ts-life');
    const run = uniqueName('run');
    try {
      const created = await client.create({ name, labels: { 'sdk-e2e': run } });
      expect(created.name).toBe(name);
      expect(created.workspace).toBe('default');
      expect(created.id).not.toBe('');
      expect(created.labels['sdk-e2e']).toBe(run);

      const ready = await client.waitReady(name, READY_TIMEOUT_SECS);
      expect(ready.id).toBe(created.id);
      expect(ready.phase).toBe('ready');
      expect((await client.get(name)).id).toBe(created.id);

      const listed = await client.listAll({ labelSelector: `sdk-e2e=${run}` });
      expect(listed.map((s) => s.id)).toEqual([created.id]);

      const deleted = await client.delete(name);
      expect(['completed', 'accepted']).toContain(deleted.outcome);
      expect(deleted.sandboxId).toBe(created.id);
      await client.waitDeleted(name, 120, { expectedSandboxId: created.id });

      const missing = await client.get(name).catch((e: unknown) => e);
      expect(missing).toBeInstanceOf(SdkError);
      expect((missing as SdkError).code).toBe('not_found');
      expect((await client.delete(name, { allowMissing: true })).outcome).toBe('already_absent');
    } finally {
      await cleanup(client, name);
    }
  });

  test('filters by label selector', async () => {
    const client = await SandboxClient.connect(connectOptions());
    const run = uniqueName('run');
    const primary = uniqueName('ts-lbl-a');
    const secondary = uniqueName('ts-lbl-b');
    try {
      await client.create({ name: primary, labels: { 'sdk-e2e': run, role: 'primary' } });
      await client.create({ name: secondary, labels: { 'sdk-e2e': run, role: 'secondary' } });

      const names = async (labelSelector: string) =>
        (await client.listAll({ labelSelector })).map((s) => s.name).sort();
      expect(await names(`sdk-e2e=${run},role=primary`)).toEqual([primary]);
      expect(await names(`sdk-e2e=${run}`)).toEqual([primary, secondary].sort());

      // Pages carry the same results as listAll.
      const paged: string[] = [];
      for await (const page of client.list({ labelSelector: `sdk-e2e=${run}`, pageSize: 1 })) {
        expect(page.items.length).toBeLessThanOrEqual(1);
        paged.push(...page.items.map((s) => s.name));
      }
      expect(paged.sort()).toEqual([primary, secondary].sort());

      await cleanup(client, primary);
      expect(await names(`sdk-e2e=${run}`)).toEqual([secondary]);
    } finally {
      await cleanup(client, primary);
      await cleanup(client, secondary);
    }
  });
});

// The tests below share one ready sandbox.
describe.skipIf(!gatewayName)('sandbox', () => {
  let client: SandboxClient;
  const name = uniqueName('ts-e2e');

  beforeAll(async () => {
    client = await SandboxClient.connect(connectOptions());
    await client.create({ name });
    await client.waitReady(name, READY_TIMEOUT_SECS);
  });

  afterAll(async () => {
    if (client) await cleanup(client, name);
  });

  test('exec returns output, exit code, and honors stdin, environment, and workdir', async () => {
    const result = await client.exec(
      name,
      ['/bin/sh', '-c', 'printf "out:%s:%s:" "$E2E_VALUE" "$(pwd)"; cat; printf err >&2; exit 3'],
      { environment: { E2E_VALUE: 'env-ok' }, workdir: '/tmp', stdin: Buffer.from('stdin-ok'), timeoutSecs: 30 },
    );
    expect(result.exitCode).toBe(3);
    expect(result.stdout.toString()).toBe('out:env-ok:/tmp:stdin-ok');
    expect(result.stderr.toString()).toBe('err');
  });

  test('execStream yields chunks, then the exit event last', async () => {
    const events: ExecStreamEvent[] = [];
    for await (const event of client.execStream(name, ['/bin/sh', '-c', 'echo one; echo two >&2; exit 5'], {
      timeoutSecs: 30,
    })) {
      events.push(event);
    }
    const last = events.at(-1);
    expect(last).toEqual({ type: 'exit', exitCode: 5 });
    const chunks = events.slice(0, -1);
    expect(chunks.every((e) => !('type' in e))).toBe(true);
    const of = (stream: string) => text(chunks.flatMap((e) => ('stream' in e && e.stream === stream ? [e.data] : [])));
    expect(of('stdout')).toBe('one\n');
    expect(of('stderr')).toBe('two\n');
  });

  test('execInteractive drains output after input EOF', async () => {
    const session = await client.execInteractive(
      name,
      ['/bin/sh', '-c', 'input=$(cat); printf "stdout:%s" "$input"; printf "stderr:drained" >&2; exit 7'],
      { tty: false, timeoutSecs: 30, signal: AbortSignal.timeout(45_000) },
    );
    try {
      // cat can't finish until closeInput reaches the sandbox, so any output
      // proves that request EOF left the response stream open.
      session.write(Buffer.from('input-before-eof'));
      session.closeInput();
      session.closeInput(); // idempotent
      const { stdout, stderr, exits } = await collect(session);
      expect(stdout).toBe('stdout:input-before-eof');
      expect(stderr).toBe('stderr:drained');
      expect(exits).toEqual([7]);
      // A nonzero process exit is not a failed transport.
      expect(await session.done).toBe(7);
      expect(session.exitCode).toBe(7);
    } finally {
      session.cancel();
    }
  });

  test('execInteractive allocates a terminal only when tty is set', async () => {
    const probe = ['/bin/sh', '-c', '[ -t 0 ] && printf T || printf N; [ -t 1 ] && printf T || printf N; echo'];
    for (const [tty, expected] of [
      [false, 'NN'],
      [true, 'TT'],
    ] as const) {
      const session = await client.execInteractive(name, probe, {
        tty,
        timeoutSecs: 30,
        signal: AbortSignal.timeout(45_000),
      });
      try {
        session.closeInput();
        const { stdout, exits } = await collect(session);
        expect(stdout.trim()).toBe(expected);
        expect(exits).toEqual([0]);
      } finally {
        session.cancel();
      }
    }
  });

  test('forward tunnels a local port to a loopback service in the sandbox', async () => {
    const port = 18765;
    // A one-connection-at-a-time HTTP server; perl is in every Ubuntu image.
    const server = await client.execInteractive(
      name,
      [
        'perl',
        '-MIO::Socket::INET',
        '-e',
        `$|=1; my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => ${port}, Listen => 5, ReuseAddr => 1) or die "listen: $!";
         print "listening\\n";
         while (my $c = $s->accept) { <$c>; print $c "HTTP/1.0 200 OK\\r\\nContent-Length: 11\\r\\n\\r\\nforward-ok\\n"; close $c; }`,
      ],
      { tty: false, timeoutSecs: 120, signal: AbortSignal.timeout(150_000) },
    );
    try {
      await waitForOutput(server, 'listening');
      // Per-connection failures go here; without it they only close the socket.
      const errors: unknown[] = [];
      const handle = await client.forward(name, { targetPort: port, onConnectionError: (e) => errors.push(e) });
      let response: string;
      try {
        expect(handle.localHost).toBe('127.0.0.1');
        expect(handle.localPort).toBeGreaterThan(0);
        response = await httpGet(handle.localHost, handle.localPort);
      } finally {
        await handle.close();
      }
      await handle.closed;
      expect(errors.map(String)).toEqual([]);
      expect(response).toMatch(/^HTTP\/1\.0 200 OK/);
      expect(response.endsWith('forward-ok\n')).toBe(true);
    } finally {
      server.cancel();
    }
  });

  test('setSetting is visible in getConfig', async () => {
    const result = await client.setSetting(name, 'ocsf_json_enabled', { value: { case: 'boolValue', value: true } });
    expect(result.deleted).toBe(false);
    const config = await client.getConfig(name);
    const setting = config.settings.ocsf_json_enabled;
    expect(setting?.scope).toBe('sandbox');
    expect(setting?.value?.value).toEqual({ case: 'boolValue', value: true });
  });

  test('watchLogs replays sandbox logs', async () => {
    const signal = AbortSignal.timeout(60_000);
    let line: { message: string; sandboxId: string } | undefined;
    const sandboxId = (await client.get(name)).id;
    for await (const event of client.watchLogs(name, { followLogs: true, logTailLines: 50, signal })) {
      if (event.kind === 'log') {
        line = event.line;
        expect(event.cursor).not.toBe('');
        break;
      }
    }
    expect(line?.sandboxId).toBe(sandboxId);
    expect(line?.message).not.toBe('');
  });
});

/** Read an interactive session to the end. */
async function collect(session: ExecInteractiveSessionControl) {
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  const exits: number[] = [];
  for await (const event of session.output) {
    expect(exits, 'exit must be the final event').toEqual([]);
    if ('type' in event) exits.push(event.exitCode);
    else (event.stream === 'stdout' ? stdout : stderr).push(event.data);
  }
  return { stdout: text(stdout), stderr: text(stderr), exits };
}

/** Consume a session's output until stdout contains marker; keep draining it afterwards. */
async function waitForOutput(session: ExecInteractiveSessionControl, marker: string): Promise<void> {
  const iterator = session.output[Symbol.asyncIterator]();
  let seen = '';
  while (!seen.includes(marker)) {
    const next = await iterator.next();
    if (next.done) throw new Error(`session ended before printing ${marker}: ${seen}`);
    if ('type' in next.value) throw new Error(`session exited (${next.value.exitCode}) before printing ${marker}`);
    seen += next.value.data.toString();
  }
  void (async () => {
    try {
      while (!(await iterator.next()).done) {}
    } catch {}
  })();
}

function httpGet(host: string, port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = tcpConnect({ host, port, noDelay: true });
    const chunks: Buffer[] = [];
    socket.setTimeout(30_000, () => socket.destroy(new Error('forwarded request timed out')));
    socket.on('connect', () => socket.write(`GET / HTTP/1.0\r\nHost: ${host}\r\n\r\n`));
    socket.on('data', (d: Buffer) => chunks.push(d));
    socket.on('end', () => resolve(text(chunks)));
    socket.on('error', reject);
  });
}
