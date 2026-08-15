/**
 * The shared layer has its own runner because it has its own tests, and running
 * them from an app would mean running them once per app.
 *
 * It still needs the react-native preset: this code imports Platform, AppState
 * and native modules even though it renders nothing.
 */
module.exports = {
  preset: 'react-native',
  rootDir: __dirname,
  setupFiles: ['./jest.setup.js'],
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?)/)',
  ],
};
