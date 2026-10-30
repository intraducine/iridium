// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <type_traits>

template<typename T> static void irDolphinOption(NSMutableArray *items, NSDictionary *values,
    const Config::Info<T>& info, const char *key, const char *title, const char *category, int maximum=1, NSArray *labels=nil) {
    id requested=values[@(key)];
    NSMutableArray *choices=[NSMutableArray array];
    for(int i=0;i<=maximum;++i) {
        NSString *value=[NSString stringWithFormat:@"%d",i];
        NSString *label=std::is_same_v<T,bool>?(i?@"On":@"Off"):labels?labels[i]:value;
        [choices addObject:@{@"value":value,@"title":label}];
        if([requested isKindOfClass:NSString.class]&&[requested isEqual:value])Config::SetCurrent(info,static_cast<T>(i));
    }
    NSString *current=[NSString stringWithFormat:@"%d",static_cast<int>(Config::Get(info))];
    [items addObject:@{@"key":@(key),@"title":@(title),@"category":@(category),@"value":current,
        @"defaultValue":[NSString stringWithFormat:@"%d",static_cast<int>(info.GetDefaultValue())],
        @"info":@"Settings apply to this game. Compatibility and CPU changes may need a new game launch.",@"choices":choices,@"visible":@YES}];
}
static NSArray *irDolphinOptions(NSDictionary *values) {
    NSMutableArray *items=[NSMutableArray array];
#define OPTION(name,title,category) irDolphinOption(items,values,Config::name,#name,title,category)
    OPTION(GFX_VSYNC,"Vertical Sync","Graphics");
    OPTION(GFX_WIDESCREEN_HACK,"Widescreen Hack","Graphics");
    OPTION(GFX_CROP,"Crop Display","Graphics");
    OPTION(GFX_ENABLE_GPU_TEXTURE_DECODING,"GPU Texture Decoding","Graphics");
    OPTION(GFX_ENABLE_PIXEL_LIGHTING,"Per-pixel Lighting","Graphics");
    OPTION(GFX_FAST_DEPTH_CALC,"Fast Depth Calculation","Compatibility");
    OPTION(GFX_HIRES_TEXTURES,"Texture Replacement","Textures");
    OPTION(GFX_CACHE_HIRES_TEXTURES,"Cache Replacement Textures","Textures");
    OPTION(GFX_DUMP_TEXTURES,"Dump Textures","Textures");
    OPTION(GFX_ENHANCE_FORCE_TRUE_COLOR,"Force True Color","Graphics");
    OPTION(GFX_ENHANCE_DISABLE_COPY_FILTER,"Disable Copy Filter","Graphics");
    OPTION(GFX_DISABLE_FOG,"Disable Fog","Graphics");
    OPTION(GFX_HACK_EFB_ACCESS_ENABLE,"EFB CPU Access","Compatibility");
    OPTION(GFX_HACK_BBOX_ENABLE,"Bounding Box","Compatibility");
    OPTION(GFX_HACK_FORCE_PROGRESSIVE,"Force Progressive Scan","Compatibility");
    OPTION(GFX_HACK_SKIP_EFB_COPY_TO_RAM,"Store EFB Copies Only on GPU","Compatibility");
    OPTION(GFX_HACK_SKIP_XFB_COPY_TO_RAM,"Store XFB Copies Only on GPU","Compatibility");
    OPTION(GFX_HACK_DEFER_EFB_COPIES,"Defer EFB Copies","Compatibility");
    OPTION(GFX_HACK_IMMEDIATE_XFB,"Immediate XFB","Compatibility");
    OPTION(GFX_HACK_SKIP_DUPLICATE_XFBS,"Skip Duplicate Frames","Compatibility");
    OPTION(GFX_HACK_COPY_EFB_SCALED,"Scaled EFB Copies","Compatibility");
    OPTION(GFX_HACK_EFB_EMULATE_FORMAT_CHANGES,"Emulate EFB Format Changes","Compatibility");
    OPTION(GFX_HACK_VERTEX_ROUNDING,"Vertex Rounding","Compatibility");
    OPTION(GFX_HACK_FAST_TEXTURE_SAMPLING,"Fast Texture Sampling","Compatibility");
    OPTION(GFX_PERF_QUERIES_ENABLE,"Performance Queries","Compatibility");
    OPTION(GFX_SHADER_CACHE,"Shader Cache","Shaders");
    OPTION(GFX_WAIT_FOR_SHADERS_BEFORE_STARTING,"Compile Shaders Before Starting","Shaders");
    OPTION(MAIN_MMU,"Memory Management Unit","CPU");
    OPTION(MAIN_SYNC_GPU,"Synchronize GPU Thread","CPU");
#undef OPTION
    irDolphinOption(items,values,Config::GFX_SHADER_COMPILATION_MODE,"GFX_SHADER_COMPILATION_MODE","Shader Mode","Shaders",3,
        @[@"Specialized",@"Exclusive Ubershaders",@"Hybrid Ubershaders",@"Skip Drawing"]);
    irDolphinOption(items,values,Config::GFX_ENHANCE_MAX_ANISOTROPY,"GFX_ENHANCE_MAX_ANISOTROPY","Anisotropic Filtering","Graphics",4,
        @[@"Off",@"2×",@"4×",@"8×",@"16×"]);
    return items;
}
