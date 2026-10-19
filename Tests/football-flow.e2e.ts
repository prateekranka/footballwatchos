import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { addManual, fixture, openFresh, tab } from './support/football-ui.ts';

test('onboarding keeps all guidance reachable and opens each step at its title', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  await tab(screen, 'Settings').tap();
  const review = screen.getByRole('button', 'Review onboarding', { exact: true });
  await screen.getByRole('collection-view').swipe({ direction: 'down' });
  await screen.scrollUntilVisible(review, { direction: 'down' });
  await app.screenshot('settings-lower');
  await review.tap();
  await app.screenshot('onboarding-welcome');
  await expect(screen.getByTestId('onboarding-title')).toHaveText('Your football sessions');
  await screen.getByTestId('onboarding-continue').tap();
  await app.screenshot('onboarding-two-ways-top');
  await screen.scrollUntilVisible(screen.getByText('Log on iPhone', { exact: true }), { direction: 'down' });
  await app.screenshot('onboarding-two-ways-lower');
  await screen.getByTestId('onboarding-continue').tap();
  await app.screenshot('onboarding-evidence-after-scroll');
  await expect(screen.getByTestId('onboarding-title')).toBeVisible();
  await screen.scrollUntilVisible(screen.getByText('Your data, clearly labelled', { exact: true }), { direction: 'down' });
  await app.screenshot('onboarding-evidence-lower');
  await screen.getByTestId('onboarding-back').tap();
  await expect(screen.getByTestId('onboarding-title')).toHaveText('Two ways to save');
  await screen.getByTestId('onboarding-continue').tap();
  await screen.getByTestId('onboarding-continue').tap();
  await tab(screen, 'Sessions').tap();
  await expect(screen.getByText('No sessions yet', { exact: true })).toBeVisible();
  await app.screenshot('sessions-empty');
});

test('duration validation rejects invalid input and Cancel leaves no session', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  await screen.getByTestId('add-session').tap();
  await app.screenshot('add-session-default');
  for (const [index, value] of ['', '0', '-1', '241', '1.5', 'ball'].entries()) {
    await screen.scrollUntilVisible(screen.getByTestId('session-duration'), { direction: 'up' });
    await screen.getByTestId('session-duration').tap();
    await expect(screen.getByRole('button', 'Done', { exact: true })).toBeVisible();
    await screen.getByTestId('session-duration').fill(value);
    // UIKit exposes the placeholder as the AX value of an empty field.
    if (value !== '') await expect(screen.getByTestId('session-duration')).toHaveValue(value);
    if (index === 1) await app.screenshot('add-session-keyboard');
    await screen.getByTestId('save-session').tap();
    await screen.scrollUntilVisible(screen.getByTestId('session-validation').first(), { direction: 'down' });
    await expect(screen.getByTestId('session-validation').first()).toBeVisible();
    await expect(screen.getByText('Enter a whole number from 1 to 240 minutes.', { exact: true })).toBeVisible();
    await app.screenshot(`add-session-invalid-${index}`);
  }
  await screen.getByRole('button', 'Cancel', { exact: true }).tap();
  await expect(screen.getByText('No sessions yet', { exact: true })).toBeVisible();
});

test('all six football types and durations persist as manual logs', { timeout: 360_000 }, async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  const sessions = [['Football', '1'], ['5-a-side', '15'], ['7-a-side', '45'], ['11-a-side', '60'], ['Training', '90'], ['Calibration', '240']];
  for (const [index, [type, minutes]] of sessions.entries()) {
    await addManual(ui, type, minutes, `manual-${index + 1}-${minutes}min`);
    await expect(screen.getByText(`${type} · Manual log`, { exact: true }).first()).toBeVisible();
  }
  await app.restart();
  await tab(screen, 'Settings').tap();
  await expect(screen.getByText('Sessions on this iPhone, 6', { exact: true })).toBeVisible();
  await app.screenshot('settings-six-manual-logs');
  await tab(screen, 'Sessions').tap();
  await expect(screen.getByText('Manual logs saved on iPhone', { exact: true })).toBeVisible();
  await screen.scrollUntilVisible(screen.getByRole('button', 'See all', { exact: true }), { direction: 'down' });
  await screen.getByRole('button', 'See all', { exact: true }).tap();
  await app.screenshot('all-manual-sessions-top');
  await screen.scrollUntilVisible(screen.getByRole('button', /Football · Manual log/).first(), { direction: 'down' });
  await app.screenshot('all-manual-sessions-bottom');
  await expect(screen.getByText('1 min', { exact: true }).first()).toBeVisible();
  await tab(screen, 'Progress').tap();
  await expect(screen.getByText('No sessions in this range yet', { exact: true })).toBeVisible();
  await app.screenshot('progress-manual-only');
});
