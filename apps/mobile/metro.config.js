const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

const projectRoot = __dirname;
// Monorepo root (apps/mobile -> ../..), so Metro watches packages/core too.
const workspaceRoot = path.resolve(projectRoot, '../..');

/**
 * Metro configuration for the cascade-react monorepo.
 * https://reactnative.dev/docs/metro
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const config = {
  // Watch the whole workspace so edits under packages/core trigger a refresh,
  // not just files inside apps/mobile.
  watchFolders: [workspaceRoot],
  resolver: {
    // Resolve from this app's own node_modules first, then the hoisted root
    // node_modules where most workspace deps actually live.
    nodeModulesPaths: [
      path.resolve(projectRoot, 'node_modules'),
      path.resolve(workspaceRoot, 'node_modules'),
    ],
  },
};

module.exports = mergeConfig(getDefaultConfig(projectRoot), config);
