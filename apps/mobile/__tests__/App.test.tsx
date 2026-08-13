/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import App from '../App';

// App now bootstraps asynchronously on mount (device id, then a stored-session
// check) before it renders sign-in or signed-in, so the render needs to happen
// inside an async act() to let that settle - a sync act() would leave the
// assertion racing the effect.
test('renders correctly', async () => {
  await ReactTestRenderer.act(async () => {
    ReactTestRenderer.create(<App />);
  });
});
