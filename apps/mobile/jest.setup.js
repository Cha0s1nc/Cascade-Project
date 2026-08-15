/**
 * Native module mocks for tests. react-native-mmkv already detects the test
 * environment itself and swaps in its in-memory mock, but react-native-device-info
 * and react-native-keychain call straight into native modules that don't exist
 * under Jest, so those two need mocking here or importing src/platform blows up
 * before a single test runs.
 */

jest.mock('react-native-device-info', () =>
  require('react-native-device-info/jest/react-native-device-info-mock'),
);

jest.mock('react-native-keychain', () => ({
  getGenericPassword: jest.fn().mockResolvedValue(false),
  setGenericPassword: jest.fn().mockResolvedValue(true),
  resetGenericPassword: jest.fn().mockResolvedValue(true),
}));

// Ships its own official mock - no reason to hand-roll one. `.default` because
// the mock module exports the replacement API as a default export, not named
// exports, and our code imports named ({ SafeAreaProvider, SafeAreaView }).
jest.mock('react-native-safe-area-context', () =>
  require('react-native-safe-area-context/jest/mock').default,
);
