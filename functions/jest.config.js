/** @type {import('ts-jest').JestConfigWithTSJest} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  collectCoverageFrom: ['src/**/*.ts', '!src/index.ts'],
  // index.ts is excluded on purpose. It is the Firebase wiring: it reads the
  // request, calls the policy, and writes to Firestore. Covering it would mean
  // running the emulator in CI for very little in return. The rules it calls
  // are covered to the branch in accessPolicy.test.ts.
  coverageThreshold: {
    global: {
      branches: 85,
      functions: 90,
      lines: 90,
      statements: 90,
    },
  },
};
