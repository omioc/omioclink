#!/usr/bin/env node
/**
 * 构建 MusicFree 插件运行时 bundle（构建期工具，运行时不依赖 Node）。
 *
 *   cd client && node tool/build_musicfree_runtime.mjs           # 生成 assets/musicfree/runtime.bundle.js
 *   cd client && node tool/build_musicfree_runtime.mjs --check   # 校验已提交产物是否最新
 *
 * 依赖都固定在 tool/musicfree-runtime/package.json（版本对齐 MusicFreeDesktop），
 * 首次运行会自动 npm install。
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const clientRoot = path.resolve(here, '..');
const projectDir = path.join(here, 'musicfree-runtime');
const outDir = path.join(clientRoot, 'assets', 'musicfree');
const outFile = path.join(outDir, 'runtime.bundle.js');
const checkOnly = process.argv.includes('--check');

const BANNER = [
  '/*!',
  ' * OmiocLink · MusicFree 插件运行时（自动生成，请勿手改）',
  ' * 生成方式：cd client && node tool/build_musicfree_runtime.mjs',
  ' * 内含：axios / cheerio / crypto-js / dayjs / big-integer / qs / he 与宿主桥接。',
  ' */',
].join('\n');

function ensureDependencies() {
  const marker = path.join(projectDir, 'node_modules', 'esbuild', 'package.json');
  if (existsSync(marker)) {
    return;
  }
  console.log('[runtime] 首次构建，安装构建依赖…');
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  execFileSync(npm, ['install', '--no-audit', '--no-fund', '--loglevel=error'], {
    cwd: projectDir,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
}

async function main() {
  ensureDependencies();
  const requireFromProject = createRequire(path.join(projectDir, 'package.json'));
  const esbuild = requireFromProject('esbuild');

  const result = await esbuild.build({
    absWorkingDir: projectDir,
    entryPoints: [path.join(projectDir, 'src', 'index.js')],
    bundle: true,
    write: false,
    format: 'iife',
    platform: 'browser',
    target: ['es2020'],
    charset: 'utf8',
    legalComments: 'none',
    logLevel: 'warning',
    alias: {
      undici: path.join(projectDir, 'src', 'undici-stub.js'),
    },
    define: {
      'process.env.NODE_ENV': '"production"',
    },
    banner: { js: BANNER },
  });

  const output = `${result.outputFiles[0].text.trimEnd()}\n`;
  if (checkOnly) {
    if (!existsSync(outFile)) {
      console.error('[runtime] 产物不存在，请先构建：' + outFile);
      process.exit(1);
    }
    const current = readFileSync(outFile, 'utf8');
    if (current !== output) {
      console.error('[runtime] 产物已过期，请重新运行 node tool/build_musicfree_runtime.mjs');
      process.exit(1);
    }
    console.log(`[runtime] 产物最新（${Buffer.byteLength(output)} 字节）`);
    return;
  }

  mkdirSync(outDir, { recursive: true });
  writeFileSync(outFile, output, 'utf8');
  console.log(`[runtime] 已生成 ${path.relative(clientRoot, outFile)}（${Buffer.byteLength(output)} 字节）`);
}

main().catch((error) => {
  console.error('[runtime] 构建失败：', error);
  process.exit(1);
});