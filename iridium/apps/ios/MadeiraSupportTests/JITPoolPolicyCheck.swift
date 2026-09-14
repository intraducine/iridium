import Foundation

let suite = "IridiumJITPoolPolicyCheck-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

assert(MadeiraJITPoolPolicy.effectiveLimitMB(requested: 0) == 256)
assert(MadeiraJITPoolPolicy.effectiveLimitMB(requested: 128) == 128)
assert(MadeiraJITPoolPolicy.effectiveLimitMB(requested: 256) == 256)
assert(MadeiraJITPoolPolicy.effectiveLimitMB(requested: 512) == 512)

var seen = -1
defaults.removeObject(forKey: MadeiraJITPoolPolicy.preferenceKey)
MadeiraJITPoolPolicy.withEffectiveLimit(defaults: defaults) {
    seen = defaults.integer(forKey: MadeiraJITPoolPolicy.preferenceKey)
}
assert(seen == 256)
assert(defaults.object(forKey: MadeiraJITPoolPolicy.preferenceKey) == nil)

defaults.set(512, forKey: MadeiraJITPoolPolicy.preferenceKey)
MadeiraJITPoolPolicy.withEffectiveLimit(defaults: defaults) {
    seen = defaults.integer(forKey: MadeiraJITPoolPolicy.preferenceKey)
}
assert(seen == 512)
assert(defaults.integer(forKey: MadeiraJITPoolPolicy.preferenceKey) == 512)

print("JIT pool policy passed")
