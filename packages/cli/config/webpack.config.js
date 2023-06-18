// gets the webpack config for build
// merges the user provided config with the default config
// and returns the merged config

// By default this generates cjs, umd builds
import merge from "lodash.mergewith";
import path from "path";
import fs from "fs";
import { BundleAnalyzerPlugin } from "webpack-bundle-analyzer";
import nodeExternals from "webpack-node-externals";
import webpack from "webpack";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
import paths, { moduleFileExtensions } from "./paths.js";
import babelConfig from "./babel.config.js";
import setherConfig from "./sether.config.js";
import { readCjsFile, readJSONFile } from "../helpers/utils.js";
import mergeWith from "lodash.mergewith";

const { appWebpackConfig, appBuild } = paths;
const { NODE_ENV = "production" } = process.env;

const pkg = readJSONFile(paths.appPackageJson);
const configImported = (await readCjsFile(appWebpackConfig)).default || { baseConfig: {} };

const babelLoaderOptions = {
  ...babelConfig,
  babelrc: false,
  configFile: false,
  cacheDirectory: true,
  cacheCompression: false,
};

if (fs.existsSync(paths.appBrowserslistConfig)) {
  babelLoaderOptions.browserslistConfigFile = paths.appBrowserslistConfig;
} else {
  babelLoaderOptions.targets = setherConfig.browserslistrc;
}

export const babelLoader = {
  test: /\.(ts|js)x?$/,
  exclude: /(node_modules|bower_components)/,
  use: {
    loader: "babel-loader",
    options: babelLoaderOptions,
  },
};

const optimization = {
  optimization: {
    minimize: false,
  },
};

const polyfillPlugins = [
  new webpack.ProvidePlugin({
    Buffer: ["buffer", "Buffer"],
  }),
  new webpack.ProvidePlugin({
    process: "process/browser.js",
  }),
];

export const resolveWebpackModule = (localPath) => {
  if (fs.existsSync(path.resolve(paths.ownNodeModules, localPath))) return new URL(paths.ownNodeModules + "/" + localPath, import.meta.url).pathname;
  else if (fs.existsSync(path.resolve(paths.appNodeModules, localPath)))
    return new URL(paths.appNodeModules + "/" + localPath, import.meta.url).pathname;

  return require.resolve(localPath);
};

const polyfillFallback = mergeWith(
  {
    http: resolveWebpackModule("stream-http/index.js"),
    https: resolveWebpackModule("https-browserify/index.js"),
    os: resolveWebpackModule("os-browserify/browser.js"),
    crypto: resolveWebpackModule("crypto-browserify/index.js"),
    assert: resolveWebpackModule("assert/build/assert.js"),
    stream: resolveWebpackModule("stream-browserify/index.js"),
    url: resolveWebpackModule("url/url.js"),
    buffer: resolveWebpackModule("buffer/index.js"),
    zlib: resolveWebpackModule("browserify-zlib/lib/index.js"),
    fs: false,
    path: false,
  },
  setherConfig.polyfillNodeDeps,
  (objValue, srcValue) => {
    if (srcValue === true) return objValue;
    if (typeof srcValue === "string") return srcValue;
    return undefined;
  }
);

function generateLibraryName(pkgName) {
  return pkgName.charAt(0).toUpperCase() + pkgName.slice(1);
}

// objValue is the first object (our default config)
function customizer(objValue, srcValue, key) {
  // merge plugins if they are not there
  if (Array.isArray(objValue) && (key === "plugins" || key === "rules")) {
    return [...objValue, ...(srcValue || [])];
  }
}

export default (pkgName) => {
  const { baseConfig: userBaseConfig, ...rest } = configImported;
  // create a copy of baseConfig every time so that loaders use new instances
  const umdConfig = merge(
    getDefaultUmdConfig(pkgName),
    merge(getDefaultBaseConfig(pkgName), userBaseConfig, customizer),
    rest.umdConfig || {},
    customizer
  );
  const cjsConfig = merge(
    getDefaultCjsConfig(pkgName),
    merge(getDefaultBaseConfig(pkgName), userBaseConfig, customizer),
    rest.cjsConfig || {},
    customizer
  );

  const finalConfigs = [];

  if (setherConfig.cjs) finalConfigs.push(cjsConfig);
  if (setherConfig.umd) finalConfigs.push(umdConfig);

  delete rest.cjsConfig;
  delete rest.umdConfig;

  // console.log("%O", ...finalConfigs.map(x => x.plugins));

  return [
    ...finalConfigs,
    ...Object.values(rest || {}).map((x) => {
      const baseConfig = merge(getDefaultBaseConfig(pkgName), userBaseConfig, customizer);
      return merge(baseConfig, x, customizer);
    }),
  ];
};

export const getDefaultBaseConfig = () => {
  return {
    mode: NODE_ENV,
    devtool: "source-map",
    entry: paths.appIndexFile,
    target: "web",
    output: {
      path: appBuild,
      library: {
        // Giving a name to builds aggregates all exports under that name
        // name:  generateLibraryName(pkgName)
      },
    },
    resolve: {
      extensions: moduleFileExtensions.map((x) => `.${x}`),
      alias: {
        "bn.js": require.resolve("bn.js/lib/bn.js"),
      },
    },
    plugins: [new webpack.IgnorePlugin({ resourceRegExp: /^\.\/wordlists\/(?!english)/, contextRegExp: /bip39\/src$/ })],
    module: {
      rules: [babelLoader],
    },
    node: {},
    // cache: {
    //   type: "filesystem",
    //   cacheDirectory: paths.appWebpackCache,
    //   store: "pack",
    //   buildDependencies: {
    //     defaultWebpack: ["webpack/lib/"],
    //     config: [paths.appPath],
    //     tsconfig: [paths.appTsConfig, paths.appTsBuildConfig].filter((f) => fs.existsSync(f)),
    //   },
    // },
  };
};

export const getDefaultUmdConfig = (pkgName) => {
  return {
    output: {
      filename: `${pkgName}.umd.min.js`,
      library: {
        type: "umd",
        // Giving a name to builds aggregates all exports under that name
        name: generateLibraryName(pkgName),
      },
    },
    plugins: [
      new webpack.optimize.LimitChunkCountPlugin({
        maxChunks: 1,
      }),
      new BundleAnalyzerPlugin({
        analyzerMode: setherConfig.analyzerMode,
        openAnalyzer: false,
      }),
      ...polyfillPlugins, // always polyfill buffer and process
    ],
    resolve: {
      fallback: polyfillFallback,
    },
  };
};

export const getDefaultCjsConfig = (pkgName) => {
  return {
    ...optimization,
    output: {
      filename: `${pkgName}.cjs.js`,
      library: {
        // Giving a name to builds aggregates all exports under that name
        type: "commonjs2",
      },
    },
    plugins: [
    ],
    externals: [...Object.keys(pkg.dependencies || {}), /^(@babel\/runtime)/i, nodeExternals()],
    externalsPresets: { node: true },
    node: {
      // Buffer: false,
    },
  };
};
