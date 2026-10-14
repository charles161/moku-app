import AppKit
import CoreGraphics

/// Renders text the way a code editor shows it: monospaced 13 pt, light on dark, at Retina scale.
enum TestImages {
    static func window(showing text: String, width: Int = 1440, height: Int = 900, scale: CGFloat = 2,
                       extraDrawing: ((CGContext) -> Void)? = nil) -> CGImage {
        let context = CGContext(data: nil, width: Int(CGFloat(width) * scale), height: Int(CGFloat(height) * scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(in: CGRect(x: 16, y: 16, width: CGFloat(width) - 32, height: CGFloat(height) - 32))
        NSGraphicsContext.current = previous
        extraDrawing?(context)
        return context.makeImage()!
    }

    /// 40 lines of real code from this repository (the old TypeScript brain’s contract.ts).
    static let code = """
        import { z } from 'zod';

        /**
         * Wire contract between the Mac app and the local brain (http://127.0.0.1:8020).
         * Mirrors app/MokuKit/Sources/MokuKit/{Perception,Brain}.swift exactly: camelCase keys,
         * dates as epoch milliseconds. Only the integrator edits this file; lanes request changes in lanes/<lane>.md.
         */

        const epochMs = z.number().int().nonnegative();

        export const AppInfo = z.object({ bundleId: z.string(), name: z.string() });
        export const WindowInfo = z.object({ title: z.string(), url: z.string().nullish() });

        export const InputActivity = z.object({
          keysPerMinute: z.number().int().nonnegative(),
          clicksPerMinute: z.number().int().nonnegative(),
          scrollsPerMinute: z.number().int().nonnegative(),
          idleSeconds: z.number().nonnegative(),
        });

        export const MeetingContext = z.object({
          inCall: z.boolean(),
          sharingScreen: z.boolean(),
          micInUse: z.boolean(),
          cameraInUse: z.boolean(),
        });

        export const ActivitySample = z.object({
          id: z.string().min(1),
          ts: epochMs,
          app: AppInfo,
          window: WindowInfo.nullish(),
          /** Focused-window text; null when unchanged since the last sample that carried text. */
          text: z.string().nullish(),
          textSource: z.enum(['accessibility', 'ocr']).nullish(),
          textHash: z.string().nullish(),
          activity: InputActivity,
          context: MeetingContext,
        });
        export type ActivitySample = z.infer<typeof ActivitySample>;
        """

    /// Different real code, for "a different screen".
    static let otherCode = """
        export const Verdict = z.object({
          sampleId: z.string(),
          state: VerdictState,
          thread: ThreadRef.nullable(),
          isNewThread: z.boolean(),
          confidence: z.number().min(0).max(1),
          source: z.enum(['shortcut', 'jev', 'override', 'fallback']),
          reason: z.string(),
          latencyMs: z.number().int().nonnegative(),
        });
        export type Verdict = z.infer<typeof Verdict>;

        export const ThreadSummary = z.object({
          id: z.string(),
          title: z.string(),
          summary: z.string(),
          focusMinutesToday: z.number().int().nonnegative(),
          focusMinutesTotal: z.number().int().nonnegative(),
          lastActiveAt: epochMs,
        });
        """
}
