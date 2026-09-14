import Foundation
import zlib

/// The guide files are a run of zlib streams stuck together, so inflating one has to report how much of the
/// input it used. That is the whole reason for going to zlib directly: it tells us what is left over, which is
/// how the next stream's start is found.
enum Inflate {
    /// Inflates one zlib stream from the start of `input` and says how many bytes it consumed.
    static func first(_ input: [UInt8]) throws -> (output: Data, consumed: Int) {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer {
            inflateEnd(stream)
            stream.deinitialize(count: 1)
            stream.deallocate()
        }
        guard inflateInit_(stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GuideError.zlib(status: Z_MEM_ERROR)
        }

        var output = Data()
        let chunkSize = 128 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status = Z_OK
        var consumed = 0
        var source = input

        source.withUnsafeMutableBufferPointer { inputBuffer in
            stream.pointee.next_in = inputBuffer.baseAddress
            stream.pointee.avail_in = uInt(inputBuffer.count)
            while status != Z_STREAM_END {
                var produced = 0
                chunk.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.pointee.next_out = outputBuffer.baseAddress
                    stream.pointee.avail_out = uInt(chunkSize)
                    status = inflate(stream, Z_NO_FLUSH)
                    produced = chunkSize - Int(stream.pointee.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }
                if status != Z_OK && status != Z_STREAM_END { break }
                // no progress and nothing left to read: the input stops mid-stream
                if status == Z_OK && produced == 0 && stream.pointee.avail_in == 0 { break }
            }
            consumed = inputBuffer.count - Int(stream.pointee.avail_in)
        }

        guard status == Z_STREAM_END else { throw GuideError.zlib(status: status) }
        return (output, consumed)
    }
}
