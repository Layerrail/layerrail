const { spawn } = require("node:child_process");
const esbuild = require("esbuild");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");

async function build() {
  const watching = process.argv.includes("--watch");
  const production = process.argv.includes("--production");
  const licenses = ['thinking-orbs', 'border-beam', 'metal-fx', 'react', 'react-dom', 'scheduler']
    .map((name) => `${name}\n${readFileSync(join('node_modules', name, 'LICENSE'), 'utf8')}`).join('\n');
  const options = {
    entryPoints: ["assets/js/playground/index.jsx"],
    outfile: "assets/js/playground.js",
    bundle: true,
    minify: production,
    target: ["es2020"],
    legalComments: "linked",
    banner: { js: `/*! Third-party licenses\n${licenses}\n*/` },
    define: { "process.env.NODE_ENV": JSON.stringify(production ? "production" : "development") },
  };
  if (watching) {
    const context = await esbuild.context(options);
    await context.watch();
  } else {
    await esbuild.build(options);
  }
  const args = [require.resolve("tailwindcss/lib/cli.js"), "-o", "assets/css/app.css", "-i", "assets/css/tailwind.css"];
  if (production) args.push("--minify");
  if (watching) args.push("--watch");
  const css = spawn(process.execPath, args, { stdio: "inherit" });
  css.on("exit", (code) => { if (!watching || code) process.exit(code ?? 1); });
  css.on("error", (error) => { console.error(error); process.exit(1); });
  for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => { css.kill(); process.exit(); });
}

build().catch((error) => { console.error(error); process.exit(1); });
