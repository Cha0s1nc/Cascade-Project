/**
 * @format
 */

import { AppRegistry } from 'react-native';
import App from './App';
import { name as appName } from './app.json';

// This used to call enableScreens(!Platform.isTV), on the theory that
// react-native-screens handed its children a zero-height container on tvOS and
// that was why Albums/Artists/Songs rendered blank. Both halves were wrong, and
// it is recorded here so nobody re-derives it: enableScreens() does not apply to
// createNativeStackNavigator at all (that always uses native RNSScreen), so the
// call could not have changed anything either way. The real cause was `flex: 1`
// on the FlatList styles - see the comment on MediaGrid's `container`.
//
// Nothing to call here now: react-navigation's native-stack enables screens on
// its own.

AppRegistry.registerComponent(appName, () => App);
