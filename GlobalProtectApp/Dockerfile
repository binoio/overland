# Runs the platform-independent GlobalProtectCore test suite on Linux.
# The SwiftUI app target is excluded automatically by Package.swift when the
# host is not macOS.
#
#   docker build -t globalprotect-core-tests -f GlobalProtectApp/Dockerfile GlobalProtectApp
#   docker run --rm globalprotect-core-tests
FROM swift:6.0-noble

WORKDIR /workspace
COPY Package.swift ./
COPY Sources/GlobalProtectCore ./Sources/GlobalProtectCore
COPY Tests/GlobalProtectCoreTests ./Tests/GlobalProtectCoreTests

RUN swift build --build-tests

CMD ["swift", "test", "--skip-build"]
