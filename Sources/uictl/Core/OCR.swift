import Vision
import CoreGraphics
import Foundation

enum OCR {
    /// Recognizes text in a CGImage (or a sub-region of it) and returns each
    /// observation's text plus its bounding box, converted to the coordinate
    /// space the caller supplies via `imageOrigin`/`scale` — useful when the
    /// image came from a window screenshot and the caller wants results back
    /// in global screen coordinates.
    static func recognizeText(in image: CGImage, region: CGRect?, imageOrigin: CGPoint, scale: CGFloat) throws -> [JSONDict] {
        var targetImage = image
        var regionOffset = imageOrigin
        if let region {
            let pixelRegion = CGRect(
                x: (region.origin.x - imageOrigin.x) * scale,
                y: (region.origin.y - imageOrigin.y) * scale,
                width: region.width * scale,
                height: region.height * scale
            ).integral
            guard let cropped = image.cropping(to: pixelRegion) else {
                throw UICtlError.message("region is outside the captured image bounds")
            }
            targetImage = cropped
            regionOffset = region.origin
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: targetImage, options: [:])
        try handler.perform([request])

        let imageWidth = CGFloat(targetImage.width)
        let imageHeight = CGFloat(targetImage.height)

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision's bounding box is normalized (0-1) with a bottom-left origin.
            let box = observation.boundingBox
            let pixelRect = CGRect(
                x: box.origin.x * imageWidth,
                y: (1 - box.origin.y - box.height) * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight
            )
            let globalRect = CGRect(
                x: regionOffset.x + pixelRect.origin.x / scale,
                y: regionOffset.y + pixelRect.origin.y / scale,
                width: pixelRect.width / scale,
                height: pixelRect.height / scale
            )
            return [
                "text": candidate.string,
                "confidence": candidate.confidence,
                "frame": globalRect.jsonDict,
            ] as JSONDict
        }
    }
}
