import { readJSONFile } from "./utils.js";

const pkg = readJSONFile(new URL("../package.json", import.meta.url));

export const helpText = `sether-cli v${pkg.version}
  Usage: sether-cli <script-name> [options]
  Use e.g. "sether-cli build" directly".
  -h --help              Print this help
  -v --version           Print sether-cli version number`;

export const startHelpText = `sether-cli v${pkg.version}
  Usage: sether-cli start [options]
  Use e.g. "sether-cli start" directly".
  -h --help              Print this help
  -n --name              Name of the project`;

export const buildHelpText = `sether-cli v${pkg.version}
  Usage: sether-cli build [options]
  Use e.g. "sether-cli build" directly".
  -h --help              Print this help
  -n --name              Name of the project`;
