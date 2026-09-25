/**
 * Shared background color for the reader route, so the status-bar strip drawn
 * by `NavDestination` follows the reader's own day/night setting instead of a
 * fixed resource color. `ReaderPage` writes it; `Index.pageMap` binds to it.
 */
@ObservedV2
export class ReaderTheme {
  private static shared: ReaderTheme | undefined = undefined;

  static instance(): ReaderTheme {
    if (ReaderTheme.shared === undefined) {
      ReaderTheme.shared = new ReaderTheme();
    }
    return ReaderTheme.shared;
  }

  @Trace bgHex: string = '#181820';
}