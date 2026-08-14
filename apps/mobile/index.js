/**
 * @format
 */

import { AppRegistry, Platform } from 'react-native';
import { enableScreens } from 'react-native-screens';
import App from './App';
import { name as appName } from './app.json';

// Native screens route each stack screen to a real UIViewController/Fragment
// instead of a plain RN view, which is cheaper on deep stacks. That is what
// react-navigation recommends, and it is correct everywhere except here.
//
// On tvOS it hands its children a zero-height container. A ScrollView survives
// that - its children just overflow and still paint - so Home and Search looked
// fine. A FlatList does not: it measures the viewport, finds no room for a
// single row, and renders nothing at all, not even ListEmptyComponent. That is
// why Albums, Artists and Songs were completely blank while the two ScrollView
// screens worked, and why it read as "the data never loaded" when the data was
// fine all along.
//
// Off on tvOS only. This app has seven screens and never stacks deeply, so the
// optimisation was worth little here and correctness beats it. Phone and
// Android keep it.
enableScreens(!Platform.isTV);

AppRegistry.registerComponent(appName, () => App);
