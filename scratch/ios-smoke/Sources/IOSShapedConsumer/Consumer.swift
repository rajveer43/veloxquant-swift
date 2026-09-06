import VeloxQuantCore

// Deliberately does not `import VeloxQuantRuntime`. If VeloxQuantRuntime's product were ever
// accidentally required transitively by VeloxQuantCore, this package would fail to resolve.
public enum Consumer {}
