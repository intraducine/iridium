import Foundation
@main struct ViewportFocusCheck {
    static func main() throws {
        for bounds in [CGRect(x:0,y:0,width:844,height:390),CGRect(x:10,y:20,width:390,height:844),CGRect(x:0,y:0,width:1024,height:768)] {
            let surface=CGSize(width:1920,height:1080)
            precondition(RuntimeViewportGeometry.aspectFitFrame(in:bounds,bottomOcclusion:0,surfaceSize:surface)==bounds)
            let frame=RuntimeViewportGeometry.aspectFitFrame(in:bounds,bottomOcclusion:190,surfaceSize:surface)
            precondition(frame.maxY <= bounds.maxY-190+0.0001)
            precondition(abs(frame.width/frame.height-16/9.0)<0.00001)
            let center=RuntimeViewportGeometry.normalizedPoint(CGPoint(x:frame.midX,y:frame.midY),in:frame)
            precondition(abs(center.x-0.5)<0.00001 && abs(center.y-0.5)<0.00001)
            let floating=CGRect(x:bounds.minX,y:bounds.maxY-150,width:200,height:150)
            precondition(RuntimeViewportGeometry.bottomOcclusion(keyboard:floating,bounds:bounds)==0)
            let docked=CGRect(x:bounds.minX,y:bounds.maxY-190,width:bounds.width,height:190)
            precondition(RuntimeViewportGeometry.bottomOcclusion(keyboard:docked,bounds:bounds)==190)
        }
        var policy=RuntimeInputFocusPolicy()
        precondition(policy.update(inputEnabled:true,keyboard:false) && policy.owner == .game)
        for _ in 0..<1000 { precondition(!policy.update(inputEnabled:true,keyboard:false)) }
        precondition(policy.update(inputEnabled:true,keyboard:true) && policy.owner == .keyboard)
        precondition(policy.update(inputEnabled:false,keyboard:true) && policy.owner == .none)
        for _ in 0..<1000 { precondition(!policy.update(inputEnabled:false,keyboard:true)) }
        precondition(policy.update(inputEnabled:true,keyboard:false) && policy.owner == .game)
        let args=["", "two words", "-flag", "quoted\"value", "c:\\folder\\", "日本語"]
        let json=try MadeiraLaunchArguments.encode(args)
        let decoded = try JSONDecoder().decode([String].self,from:Data(json.utf8))
        precondition(decoded == args)
        for invalid in [["a\0b"],Array(repeating:"x",count:257),[String(repeating:"x",count:65537)]] {
            do { _=try MadeiraLaunchArguments.encode(invalid); fatalError("invalid argv accepted") } catch is CocoaError {}
        }
        print("PASS viewport geometry, docked/floating keyboards, input remapping, focus ownership and lossless argument transport")
    }
}
