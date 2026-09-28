#import <AppKit/AppKit.h>
#include "tc_host.h"
#include "tc_threads.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/xattr.h>

/* Generated C ABI wrapper for the recovered executable CRT startup routine.
 * This bypasses the original packing wrapper; startup equivalence remains
 * incomplete. The development target is not a playable release. */
#ifdef TC_DYNAMIC_GAME_CODE
/* Release builds ship no game code: on first launch the bundled converter
 * translates the player's own TrueCrime.exe into a bundle that is loaded here. */
static void (*c_tc_loc_665BD1)(_cpu *cpu);
static void (*tc_guest_invoke)(_cpu *cpu,uint32_t address);
/* -all_load links llasm_fs_mem, whose FS callbacks the translation never uses
 * (it calls tc_read_fs instead). */
uint32_t X86_ReadFsDword(uint32_t address) {(void)address;abort();}
void X86_WriteFsDword(uint32_t address,uint32_t value) {(void)address;(void)value;abort();}
#else
extern void c_tc_loc_665BD1(_cpu *cpu);
extern void tc_guest_invoke(_cpu *cpu,uint32_t address);
#endif
uint32_t X86_InterruptFlag = 1;
void X86_InterruptProcedure(uint8_t number, void *registers) {
    (void)registers;
    fprintf(stderr,"Unsupported guest interrupt 0x%02x\n",number);
    abort();
}

static BOOL game_directory(NSString *path) {
    if(!path.length)return NO;
    NSFileManager *files=[NSFileManager defaultManager];BOOL directory=NO;
    return [files isReadableFileAtPath:[path stringByAppendingPathComponent:@"TrueCrime.exe"]]&&
        [files fileExistsAtPath:[path stringByAppendingPathComponent:@"DATA"] isDirectory:&directory]&&directory;
}
static NSString *default_game_directory(void) {
    NSBundle *bundle=[NSBundle mainBundle];
    NSString *beside=[bundle.bundlePath stringByDeletingLastPathComponent];
    NSString *saved=[[NSUserDefaults standardUserDefaults]stringForKey:@"GameDirectory"];
    NSArray<NSString *> *candidates=@[
        [bundle.resourcePath stringByAppendingPathComponent:@"GameData"] ?: @"",
        [beside stringByAppendingPathComponent:@"Put game files here"] ?: @"",beside ?: @"",
        saved ?: @"",[NSFileManager defaultManager].currentDirectoryPath,@TC_GAME_DIRECTORY];
    for(NSString *path in candidates)if(game_directory(path))return path.stringByStandardizingPath;
    return nil;
}

@interface TCApplication : NSObject<NSApplicationDelegate> {
    tc_image image;
}
@property(strong) NSWindow *progressWindow;
@property(strong) NSProgressIndicator *progressBar;
@property(strong) NSTextField *progressText;
@property(copy) NSString *gameDirectory;
@property BOOL headless, audioDisabled;
@end
@implementation TCApplication
- (void)fail:(NSString *)message {
    fprintf(stderr,"True Crime startup failed: %s\n",message.UTF8String);
    if(self.headless)exit(1);
    NSAlert *alert=[NSAlert new];alert.messageText=@"True Crime could not start";
    alert.informativeText=message;[alert runModal];[NSApp terminate:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    /* Holding Option chooses a different installation. */
    if(!self.headless&&(NSEvent.modifierFlags&NSEventModifierFlagOption))self.gameDirectory=nil;
    while(!self.gameDirectory&&!self.headless) {
        NSOpenPanel *panel=[NSOpenPanel openPanel];
        panel.title=@"Choose True Crime game files";
        panel.message=@"Choose your installed True Crime: Streets of LA folder (it contains TrueCrime.exe and DATA).";
        panel.canChooseFiles=NO;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=NO;
        if([panel runModal]!=NSModalResponseOK){[NSApp terminate:nil];return;}
        if(game_directory(panel.URL.path)){self.gameDirectory=panel.URL.path;break;}
        NSAlert *alert=[NSAlert new];alert.messageText=@"Game files not found";
        alert.informativeText=@"That folder does not contain TrueCrime.exe and a DATA folder. Choose the installed game folder, not an installer.";
        [alert runModal];
    }
    if(!self.gameDirectory){[self fail:@"Game files not found. Pass the game directory after --headless."];return;}
    NSString *executable=[self.gameDirectory stringByAppendingPathComponent:@"TrueCrime.exe"];
    char error[256];
    if(tc_image_open(&image,executable.fileSystemRepresentation,error,sizeof(error))) {
        NSString *message=[NSString stringWithUTF8String:error];
        if([message hasPrefix:@"Unsupported executable"])
            message=@"This TrueCrime.exe is not the supported version. Use the English PC release (TrueCrime.exe, 2,932,736 bytes), unmodified.";
        [self fail:message];return;
    }
    if(!self.headless)[[NSUserDefaults standardUserDefaults]setObject:self.gameDirectory forKey:@"GameDirectory"];
#ifdef TC_DYNAMIC_GAME_CODE
    [self prepareGameCode:executable];
}
- (void)startGame {
#endif
    image.cpu.headless=self.headless;
    image.cpu.audio_disabled=self.audioDisabled;
    image.cpu.guest_invoke=tc_guest_invoke;
    NSError *directoryError=nil;
    NSURL *support=[[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&directoryError];
    NSURL *folder=[support URLByAppendingPathComponent:@"TrueCrimeNative" isDirectory:YES];
    if(!folder||![[NSFileManager defaultManager]createDirectoryAtURL:folder withIntermediateDirectories:YES
        attributes:nil error:&directoryError]) {
        tc_image_close(&image);[self fail:directoryError.localizedDescription ?: @"Could not create the settings directory."];return;
    }
    NSString *preferences=[[folder URLByAppendingPathComponent:@"settings.plist"]path];
    if(chdir(self.gameDirectory.fileSystemRepresentation)) {
        tc_image_close(&image);[self fail:@"Could not open the game directory."];return;
    }
    if(tc_host_open(&image,preferences.fileSystemRepresentation)) {
        tc_image_close(&image);[self fail:@"Could not initialize Metal, the game window, or saved settings."];return;
    }
    if(!self.headless)[NSApp activateIgnoringOtherApps:YES];
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            c_tc_loc_665BD1(&self->image.cpu.scalar);
            tc_threads_main_returned(self->image.cpu.threads,self->image.cpu.scalar._eax);
            dispatch_async(dispatch_get_main_queue(),^{
                /* Process exit stops any outstanding native workers. Never unmap
                   their shared image while they may still be executing. */
                if(tc_threads_active(self->image.cpu.threads)){[NSApp terminate:nil];return;}
                tc_host_close(&self->image);tc_image_close(&self->image);
                [NSApp terminate:nil];
            });
        }
    }];
}
#ifdef TC_DYNAMIC_GAME_CODE
- (BOOL)loadGameCode:(NSString *)path {
    void *handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    if(!handle){fprintf(stderr,"Converted game code could not be loaded: %s\n",dlerror());return NO;}
    c_tc_loc_665BD1=(void (*)(_cpu *))dlsym(handle,"c_tc_loc_665BD1");
    tc_guest_invoke=(void (*)(_cpu *,uint32_t))dlsym(handle,"tc_guest_invoke");
    if(c_tc_loc_665BD1&&tc_guest_invoke)return YES;
    dlclose(handle);return NO;
}
- (void)showProgress {
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,460,128)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title=@"True Crime";window.releasedWhenClosed=NO;
    NSTextField *title=[NSTextField labelWithString:@"Preparing True Crime for this Mac"];
    title.font=[NSFont boldSystemFontOfSize:15];title.frame=NSMakeRect(20,88,420,22);
    NSTextField *detail=[NSTextField labelWithString:@"One-time setup, about 1–2 minutes. Your game files are not changed."];
    detail.textColor=NSColor.secondaryLabelColor;detail.frame=NSMakeRect(20,64,420,18);
    NSProgressIndicator *bar=[[NSProgressIndicator alloc]initWithFrame:NSMakeRect(20,36,420,20)];
    bar.indeterminate=NO;bar.minValue=0;bar.maxValue=100;
    NSTextField *step=[NSTextField labelWithString:@"Starting"];
    step.font=[NSFont systemFontOfSize:11];step.textColor=NSColor.secondaryLabelColor;step.frame=NSMakeRect(20,12,420,16);
    for(NSView *view in @[title,detail,bar,step])[window.contentView addSubview:view];
    [window center];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    self.progressWindow=window;self.progressBar=bar;self.progressText=step;
}
- (void)progressLine:(NSString *)line {
    if(self.headless){fprintf(stderr,"%s\n",line.UTF8String);return;}
    NSArray<NSString *> *parts=[line componentsSeparatedByString:@" "];
    if(parts.count<3||![parts[0] isEqualToString:@"PROGRESS"])return;
    self.progressBar.doubleValue=parts[1].doubleValue;
    self.progressText.stringValue=[[parts subarrayWithRange:NSMakeRange(2,parts.count-2)]componentsJoinedByString:@" "];
}
static void clear_quarantine(NSString *root) {
    removexattr(root.fileSystemRepresentation,"com.apple.quarantine",XATTR_NOFOLLOW);
    for(NSString *name in [[NSFileManager defaultManager]enumeratorAtPath:root])
        removexattr([root stringByAppendingPathComponent:name].fileSystemRepresentation,"com.apple.quarantine",XATTR_NOFOLLOW);
}
/* The converted code is cached per app build under Application Support.
 * The converter runs from a private copy so a downloaded (quarantined or
 * translocated) app can still execute its bundled tools. */
- (void)prepareGameCode:(NSString *)executable {
    NSFileManager *files=[NSFileManager defaultManager];NSBundle *bundle=[NSBundle mainBundle];
    NSString *identifier=[bundle objectForInfoDictionaryKey:@"TCGameCodeID"];
    NSString *tools=[bundle.resourcePath stringByAppendingPathComponent:@"Recompiler"];
    NSURL *support=[files URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSString *root=[support.path stringByAppendingPathComponent:@"TrueCrimeNative/GameCode"];
    if(!identifier.length||![files fileExistsAtPath:tools]||!root){[self fail:@"This build does not include the game-code converter."];return;}
    NSString *folder=[root stringByAppendingPathComponent:identifier];
    NSString *output=[folder stringByAppendingPathComponent:@"truecrime.bundle"];
    if([files fileExistsAtPath:output]&&[self loadGameCode:output]){[self startGame];return;}
    for(NSString *old in [files contentsOfDirectoryAtPath:root error:nil])
        [files removeItemAtPath:[root stringByAppendingPathComponent:old] error:nil];
    NSString *converter=[folder stringByAppendingPathComponent:@"converter"];
    NSError *error=nil;
    if(![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error]||
       ![files copyItemAtPath:tools toPath:converter error:&error]) {
        [self fail:[@"Could not prepare the converter: " stringByAppendingString:error.localizedDescription]];return;
    }
    clear_quarantine(converter);
    NSString *logPath=[root stringByAppendingPathComponent:@"convert.log"];
    [files createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *log=[NSFileHandle fileHandleForWritingAtPath:logPath];
    NSTask *task=[NSTask new];
    task.executableURL=[NSURL fileURLWithPath:[converter stringByAppendingPathComponent:@"python/bin/python3"]];
    task.arguments=@[[converter stringByAppendingPathComponent:@"native/recompile.py"],executable,output,
        @"--work",[folder stringByAppendingPathComponent:@"work"]];
    task.environment=@{@"PATH":@"/usr/bin:/bin",@"HOME":NSHomeDirectory(),@"PYTHONNOUSERSITE":@"1",@"PYTHONDONTWRITEBYTECODE":@"1"};
    NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=pipe;
    NSMutableData *pending=[NSMutableData new];__block NSString *lastError=nil;
    pipe.fileHandleForReading.readabilityHandler=^(NSFileHandle *handle) {
        NSData *data=handle.availableData;if(!data.length)return;
        [log writeData:data];
        @synchronized(pending) {
            [pending appendData:data];
            NSString *text=[[NSString alloc]initWithData:pending encoding:NSUTF8StringEncoding];
            NSRange end=[text rangeOfString:@"\n" options:NSBackwardsSearch];
            if(!text||end.location==NSNotFound)return;
            NSArray<NSString *> *lines=[[text substringToIndex:end.location]componentsSeparatedByString:@"\n"];
            [pending setData:[[text substringFromIndex:end.location+1]dataUsingEncoding:NSUTF8StringEncoding]];
            for(NSString *line in lines) {
                if([line hasPrefix:@"ERROR "])lastError=[line substringFromIndex:6];
                dispatch_async(dispatch_get_main_queue(),^{[self progressLine:line];});
            }
        }
    };
    task.terminationHandler=^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(),^{
            pipe.fileHandleForReading.readabilityHandler=nil;
            [log writeData:[pipe.fileHandleForReading readDataToEndOfFile]];[log closeFile];
            [files removeItemAtPath:converter error:nil];
            [self.progressWindow orderOut:nil];self.progressWindow=nil;
            if(finished.terminationStatus==0&&[self loadGameCode:output]){[self startGame];return;}
            [files removeItemAtPath:output error:nil];
            [self fail:[NSString stringWithFormat:@"Preparing the game failed%@%@. Details: %@",
                lastError?@": ":@"",lastError?:@"",logPath]];
        });
    };
    if(!self.headless)[self showProgress];
    if(![task launchAndReturnError:&error]) {
        [self.progressWindow orderOut:nil];
        [self fail:[@"Could not start the converter: " stringByAppendingString:error.localizedDescription]];
    }
}
#endif
/* Until guest quit-message delivery exists, quitting terminates the process.
 * Do not unmap image memory while its game thread is still executing. */
@end
int main(int argc,const char **argv) {
    @autoreleasepool {
        static TCApplication *delegate;
        delegate=[TCApplication new];const char *directory=NULL;
        for(int i=1;i<argc;i++) {
            if(!strcmp(argv[i],"--headless"))delegate.headless=YES;
            else if(!strcmp(argv[i],"--no-audio"))delegate.audioDisabled=YES;
            else if(!strcmp(argv[i],"--help")) {
                puts("Usage: tc_game [--headless] [--no-audio] [game-directory]\n"
                    "--headless: offscreen Metal, no window, no audio device.\n"
                    "--no-audio: visible game without opening an audio device.\n"
                    "Game files: TrueCrime.exe and DATA. Omit the directory to use bundled,\n"
                    "adjacent, saved, current-directory, or development game files.");return 0;
            }
            else if(argv[i][0]=='-'){fprintf(stderr,"Unknown option: %s\n",argv[i]);return 2;}
            else if(directory){fprintf(stderr,"Only one game directory is accepted\n");return 2;}
            else directory=argv[i];
        }
        if(directory) {
            NSString *path=[NSString stringWithUTF8String:directory];
            if(!path){fprintf(stderr,"Invalid game directory encoding\n");return 1;}
            if(!path.isAbsolutePath)path=[[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:path];
            delegate.gameDirectory=path.stringByStandardizingPath;
            if(!game_directory(delegate.gameDirectory)) {
                fprintf(stderr,"Game directory must contain readable TrueCrime.exe and a DATA folder\n");return 1;
            }
        } else delegate.gameDirectory=default_game_directory();
        if(delegate.headless)fprintf(stderr,"Headless mode: no window, no audio device, offscreen Metal.\n");
        [NSApplication sharedApplication];NSApp.delegate=delegate;
        [NSApp setActivationPolicy:delegate.headless?NSApplicationActivationPolicyProhibited:NSApplicationActivationPolicyRegular];
        [NSApp run];
    }
    return 0;
}
