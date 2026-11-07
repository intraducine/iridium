// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "GPU/Common/PostShader.h"

struct IRPSPOption {
    const char *key, *title, *category;
    bool *boolean = nullptr;
    int *integer = nullptr;
    int minimum = 0, maximum = 1;
};
static bool irPSPStartupKey(NSString *key) {
    return [key isEqual:@"bSoftwareRendering"] || [key isEqual:@"iPSPModel"];
}
static NSArray *irPSPOptions(NSString *key, NSString *value, bool *accepted) {
    const IRPSPOption fields[] = {
#define BOOL(member,title,category) {#member,title,category,&g_Config.member}
#define INT(member,title,category,low,high) {#member,title,category,nullptr,&g_Config.member,low,high}
        BOOL(bSoftwareRendering,"Software Rendering","Graphics"),
        BOOL(bHardwareTransform,"Hardware Transform","Graphics"),
        BOOL(bSoftwareSkinning,"Software Skinning","Graphics"),
        BOOL(bTextureBackoffCache,"Lazy Texture Caching","Graphics"),
        BOOL(bSmart2DTexFiltering,"Smart 2D Filtering","Graphics"),
        BOOL(bReplaceTextures,"Texture Replacement","Textures"),
        BOOL(bSaveNewTextures,"Dump New Textures","Textures"),
        BOOL(bTexDeposterize,"Deposterize Textures","Textures"),
        BOOL(bTexHardwareScaling,"GPU Texture Scaling","Textures"),
        BOOL(bAutoFrameSkip,"Automatic Frame Skip","Performance"),
        BOOL(bSkipBufferEffects,"Skip Buffer Effects","Performance"),
        BOOL(bDisableRangeCulling,"Disable Range Culling","Compatibility"),
        BOOL(bEnableCheats,"Enable Cheats","Cheats"),
        BOOL(bEnableWlan,"Networking","Multiplayer"),
        BOOL(bEnableAdhocServer,"Host Ad Hoc Server","Multiplayer"),
        BOOL(bEnableUPnP,"UPnP Port Mapping","Multiplayer"),
        BOOL(bForcedFirstConnect,"Force First Connect","Multiplayer"),
        INT(iPortOffset,"Port Offset","Multiplayer",0,60000),
        INT(iMinTimeout,"Minimum Timeout (ms)","Multiplayer",0,15000),
        INT(iWlanAdhocChannel,"WLAN Channel","Multiplayer",0,11),
        INT(iInternalResolution,"Resolution","Graphics",1,4),
        INT(iFrameSkip,"Frame Skip","Performance",0,8),
        INT(iAnisotropyLevel,"Anisotropic Filtering","Graphics",0,4),
        INT(iTexFiltering,"Texture Filtering","Textures",1,4),
        INT(iTexScalingLevel,"Texture Scaling","Textures",1,5),
        INT(iTexScalingType,"Texture Upscaler","Textures",0,3),
        INT(iSkipGPUReadbackMode,"GPU Readback Mode","Compatibility",0,2),
        INT(iSplineBezierQuality,"Spline and Bezier Quality","Graphics",0,2),
        INT(iPSPModel,"PSP Model","System",0,1),
#undef BOOL
#undef INT
    };
    NSDictionary *labels=@{
        @"iWlanAdhocChannel":@[@"Auto",@"1",@"6",@"11"],
        @"iAnisotropyLevel":@[@"Off",@"2×",@"4×",@"8×",@"16×"],
        @"iTexFiltering":@[@"Auto",@"Nearest",@"Linear",@"Auto Max Quality"],
        @"iTexScalingLevel":@[@"Off",@"2×",@"3×",@"4×",@"5×"],
        @"iTexScalingType":@[@"xBRZ",@"Hybrid",@"Bicubic",@"Hybrid and Bicubic"],
        @"iSkipGPUReadbackMode":@[@"No",@"Skip",@"Copy to Texture"],
        @"iSplineBezierQuality":@[@"Low",@"Medium",@"High"],
        @"iPSPModel":@[@"PSP-1000",@"PSP-2000/3000"],
    };
    NSMutableArray *items=[NSMutableArray array];
    for(const auto &field:fields) {
        NSMutableArray *choices=[NSMutableArray array];
        NSArray *names=labels[@(field.key)];
        for(int i=field.minimum;field.maximum-field.minimum<=32&&i<=field.maximum;++i) {
            bool channel=strcmp(field.key,"iWlanAdhocChannel")==0;
            if(channel&&i!=0&&i!=1&&i!=6&&i!=11)continue;
            NSString *number=[NSString stringWithFormat:@"%d",i];
            NSString *title=channel?(i?number:@"Auto"):field.boolean?(i?@"On":@"Off"):names?names[i-field.minimum]:number;
            [choices addObject:@{@"value":number,@"title":title}];
        }
        bool startup=irPSPStartupKey(@(field.key));
        if(!startup&&key&&[key isEqual:@(field.key)]&&[value isKindOfClass:NSString.class]) {
            if(choices.count==0&&value.length>0&&value.length<=6&&[value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"]invertedSet]].location==NSNotFound&&
               value.intValue>=field.minimum&&value.intValue<=field.maximum) {
                *field.integer=value.intValue;*accepted=true;
            }
            for(NSDictionary *choice in choices)if([choice[@"value"] isEqual:value]) {
                if(field.boolean)*field.boolean=value.intValue!=0;
                else *field.integer=value.intValue;
                *accepted=true;break;
            }
        }
        NSString *current=[NSString stringWithFormat:@"%d",field.boolean?(int)*field.boolean:*field.integer];
        NSString *info=field.maximum-field.minimum>32?[NSString stringWithFormat:@"Enter a whole number from %d to %d. Reopen the game to reconnect.",field.minimum,field.maximum]:@"Changes apply on resume. Some options need a new game launch.";
        if(startup)info=@"Applies on the next game launch.";
        [items addObject:@{@"key":@(field.key),@"title":@(field.title),@"category":@(field.category),
            @"value":current,@"defaultValue":current,@"info":info,
            @"choices":choices,@"visible":@YES,@"restartRequired":@(startup)}];
    }
    if(GetAllPostShaderInfo().empty())ReloadAllPostShaderInfo(nullptr);
    NSMutableArray *shaders=[NSMutableArray array];
    for(const auto &shader:GetAllPostShaderInfo())if(shader.visible||shader.section=="Off")
        [shaders addObject:@{@"value":@(shader.section.c_str()),@"title":@(shader.name.c_str())}];
    if([key isEqual:@"postShader"])for(NSDictionary *shader in shaders)if([shader[@"value"] isEqual:value]) {
        g_Config.vPostShaderNames.clear();
        if(![value isEqual:@"Off"])g_Config.vPostShaderNames.push_back(value.UTF8String);
        *accepted=true;break;
    }
    NSString *shader=g_Config.vPostShaderNames.empty()?@"Off":@(g_Config.vPostShaderNames.front().c_str());
    [items addObject:@{@"key":@"postShader",@"title":@"Post-processing Shader",@"category":@"Graphics",@"value":shader,
        @"defaultValue":@"Off",@"info":@"Select a shader from PPSSPP's bundled or imported shaders.",@"choices":shaders,@"visible":@YES}];
    if([key isEqual:@"sProAdhocServer"]&&[value isKindOfClass:NSString.class]&&value.length>0&&value.length<=253&&
       [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]_"] invertedSet]].location==NSNotFound) {
        g_Config.sProAdhocServer=value.UTF8String;*accepted=true;
    }
    [items addObject:@{@"key":@"sProAdhocServer",@"title":@"Ad Hoc Server Address",@"category":@"Multiplayer",
        @"value":@(g_Config.sProAdhocServer.c_str()),@"defaultValue":@"",@"info":@"Enter the server's host name or IP address. Reopen the game to reconnect.",@"choices":@[],@"visible":@YES}];
    return items;
}
