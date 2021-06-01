package zlib

import "core:fmt"
import "core:time"

@static SECTION_LEVEL := 0;
@static ROOT_SECTION: Timed_Section;
@static CURRENT_SECTION: ^Timed_Section;

@static PROFILER: Profiler;
Profiler :: struct
{
    sections: [dynamic]^Timed_Section,
    current_section: ^Timed_Section,
}

Timed_Section :: struct
{
    name: string,
    start_time: time.Time,
    
    calls: u64,
    total_time: time.Duration,
    
    children: [dynamic]^Timed_Section,
    parent: ^Timed_Section,
}

@(deferred_out=end_timed_section)
TIMED_SECTION :: #force_inline proc(name_override: string = "", loc := #caller_location) -> ^Timed_Section
{
    return start_timed_section(name_override, loc);
}

start_timed_section :: #force_inline proc(name_override: string = "", loc := #caller_location) -> ^Timed_Section
{
    profile_start_time := time.now();
    
    section: ^Timed_Section;
    name: string;
    if name_override != "" 
    {
        name = name_override;
    }
    else 
    {
        name = loc.procedure;
    }
    
    if PROFILER.current_section != nil
    {
        for child in PROFILER.current_section.children
        {
            if child.name == name
            {
                section = child;
                break;
            }
        }
        if section == nil
        {
            section = new(Timed_Section);
            section.name = name;
            section.parent = PROFILER.current_section;
            append(&PROFILER.current_section.children, section);
        }
    }
    else
    {
        for sec in PROFILER.sections
        {
            if sec.name == name
            {
                section = sec;
                break;
            }
        }
        if section == nil
        {
            section = new(Timed_Section);
            section.name = name;
            section.parent = PROFILER.current_section;
            append(&PROFILER.sections, section);
        }
    }
    
    if PROFILER.current_section != nil 
    {
        PROFILER.current_section.total_time -= time.diff(profile_start_time, time.now());
    }
    
    section.start_time = time.now();
    
    PROFILER.current_section = section;
    return section;
}

end_timed_section :: #force_inline proc(using section: ^Timed_Section)
{
    end_time := time.now();
    elapsed := time.diff(start_time, end_time);
    calls += 1;
    total_time += elapsed;
    PROFILER.current_section = section.parent;
    if PROFILER.current_section != nil 
    {
        PROFILER.current_section.total_time -= time.diff(end_time, time.now());
    }
}

@(private="file")
print_section_info :: proc(using section: ^Timed_Section, level := 0)
{
    percent: f64;
    if parent != nil 
    {
        percent = f64(total_time)/f64(parent.total_time);
    }
    else 
    {
        percent = 0;
    }
    for _ in 0..level do fmt.printf("  ");
    fmt.printf("%s: {{%.2f%%, %fms}}\n", name, percent, (f64(total_time)/f64(calls)/f64(time.Millisecond)));
    for child in children 
    {
        print_section_info(child, level+1);
    }
}

print_profiler_info :: proc()
{
    using PROFILER;
    
    fmt.printf("\033[2J\033[H");
    for section in sections 
    {
        print_section_info(section);
    }
}

