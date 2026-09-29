import Foundation
import Testing
import PlayerCore
@testable import LingoPlayer

struct AlignmentResourceTests {
    @Test func mathLibrariesStaySingleThreadedInDescendants() async throws {
        let code = """
        import os, subprocess, sys
        keys = ['OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS', 'NUMEXPR_NUM_THREADS']
        assert all(os.environ[key] == '1' for key in keys)
        subprocess.run([sys.executable, '-c', 'import os, sys; assert all(os.environ[key] == "1" for key in sys.argv[1:])'] + keys, check=True)
        print('inherited')
        """
        let result = try await ProcessRunner.run(executable: "/usr/bin/python3",
            arguments: ["-c", code],
            environment: AlignmentCoordinator.workerEnvironment, timeout: 10, qualityOfService: .utility)
        #expect(String(data: result.output, encoding: .utf8)?.contains("inherited") == true)
    }
}
