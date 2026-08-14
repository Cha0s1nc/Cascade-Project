/**
 * @format
 */

import { AppRegistry } from 'react-native';
import { enableScreens } from 'react-native-screens';
import App from './App';
import { name as appName } from './app.json';

// Recommended by react-navigation's native-stack docs: routes each stack
// screen to a native UIViewController/Fragment instead of a plain RN view, for
// less overhead on deep stacks. Belongs here, once, before anything renders.
enableScreens();

AppRegistry.registerComponent(appName, () => App);
