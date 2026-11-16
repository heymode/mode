/* Installing on Android (#android). Every "Mode for Android" link on the site comes here, not to the APK:
   Play Protect blocks a browser, messaging app or file manager from installing an app that declares an
   accessibility service, and Mode needs one to tap for you. So the APK is offered only inside a route.

   The words live in COPY and ROUTES below; the order of the routes is ROUTE_ORDER, one line. */
import type { ReactNode } from 'react';
import { withVisitor } from '../lib/analytics';
import { ANDROID_HREF } from '../lib/platform';
import { REPO } from '../links';

type RouteId = 'installer' | 'computer' | 'pause';

/** Which route comes first. The first one is marked as the recommended way. */
const ROUTE_ORDER: RouteId[] = ['installer', 'computer', 'pause'];

// DRAFT WORDING (cmp-engineer, from play-protect-options.md). Replaced by marketing's android-install.md before review.
const COPY = {
  pill: 'Android 13 or later · free · open source',
  title: <>Installing <em>on Android.</em></>,
  why: "Google's Play Protect blocks any app that uses Android's accessibility service when you install it from a browser, a messaging app or a file manager. Mode needs that service: it's how Mode sees the screen and taps for you. The block is about where the file comes from, not about what Mode does, and the dialog has no \"Install anyway\". So pick one of these ways instead.",
  after: <>Once it's installed, Mode walks you through turning on Phone control. Every release's APK and its SHA-256 are on <a href={`${REPO}/releases`} target="_blank" rel="noopener" data-ev="github_click" data-where="android">GitHub</a>.</>,
};

const apk = (label: string, where: string) => (
  <a className="btn soft dl" href={withVisitor(ANDROID_HREF, where)} data-ev="download_click" data-where={where} data-target="android">{label}</a>
);

const ROUTES: Record<RouteId, { title: string; who: string; steps: ReactNode[]; action?: ReactNode }> = {
  installer: {
    title: 'With an installer app',
    who: 'On the phone, no computer.',
    steps: [
      <>Install <a href="https://github.com/ImranR98/Obtainium/releases/latest" target="_blank" rel="noopener" data-ev="out_click" data-where="android" data-target="obtainium">Obtainium</a>, a free open-source app that installs apps from GitHub.</>,
      <>In Obtainium, add <code>github.com/heymode/mode</code>.</>,
      <>Tap Install. Obtainium also tells you when there's a new version.</>,
    ],
    action: <a className="btn soft" href="obtainium://add/https://github.com/heymode/mode" data-ev="out_click" data-where="android" data-target="obtainium-add">Add Mode to Obtainium</a>,
  },
  computer: {
    title: 'From a computer',
    who: 'For people who have used adb before.',
    steps: [
      <>On the phone, turn on Developer options and USB debugging, then plug it into your computer.</>,
      <>Download <code>mode-android.apk</code> on the computer.</>,
      <>Run <code>adb install mode-android.apk</code>.</>,
    ],
    action: apk('Download mode-android.apk', 'android-computer'),
  },
  pause: {
    title: 'Pause Play Protect for one install',
    who: "Google advises keeping Play Protect on. Turn it back on straight after.",
    steps: [
      <>Open the Play Store, tap your picture, then Play Protect, then the settings icon, and turn off <b>Scan apps with Play Protect</b>.</>,
      <>Download Mode below and install it.</>,
      <><b>Turn Play Protect back on</b> in the same place.</>,
    ],
    action: apk('Download Mode for Android', 'android-pause'),
  },
};

export function AndroidInstall() {
  return (
    <section className="wrap" id="android" data-section="android" aria-labelledby="android-h" style={{ scrollMarginTop: 'calc(24px + var(--sat))' }}>
      <div className="droid setup rv">
        <ul className="pills"><li className="now">{COPY.pill}</li></ul>
        <h2 id="android-h">{COPY.title}</h2>
        <p>{COPY.why}</p>
        <ol className="routes">
          {ROUTE_ORDER.map((id, i) => {
            const r = ROUTES[id];
            return (
              <li key={id} data-route={id}>
                <b>{r.title}{i === 0 && <span className="rec">Recommended</span>}</b>
                <span className="who">{r.who}</span>
                <ol>{r.steps.map((s, j) => <li key={j}>{s}</li>)}</ol>
                {r.action && <div className="row">{r.action}</div>}
              </li>
            );
          })}
        </ol>
        <p className="need">{COPY.after}</p>
      </div>
    </section>
  );
}
