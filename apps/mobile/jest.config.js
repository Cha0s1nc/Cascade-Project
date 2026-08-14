module.exports = {
  preset: 'react-native',
  setupFiles: ['./jest.setup.js'],
  // The react-native preset's own transformIgnorePatterns only whitelists
  // react-native itself; @react-navigation and react-native-screens ship ESM
  // in node_modules too and need the same babel-jest pass or `require` chokes
  // on their `export` statements.
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?|@react-navigation|react-native-screens)/)',
  ],
  // react-native-screens is pinned to 4.25.0 (see package.json) because 4.27's
  // Fabric codegen uses React.ComponentRef, which this RN 0.83 tvos prerelease's
  // bundled @react-native/codegen doesn't recognize yet - `react-native bundle`
  // fails outright otherwise. That pin makes npm nest it in apps/mobile's own
  // node_modules instead of hoisting to the workspace root. Metro already knows
  // to look in both places (metro.config.js's nodeModulesPaths); Jest's plain
  // Node resolution does not, hence this mapping.
  moduleNameMapper: {
    '^react-native-screens$': '<rootDir>/node_modules/react-native-screens',
  },
};
