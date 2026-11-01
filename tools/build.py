from pathlib import Path
import re
import sys

source=Path('src/window.lua').read_text(encoding='utf-8')
parts={}
matches=list(re.finditer(r'^function window:(\w+)\(',source,re.M))
for i,m in enumerate(matches):
    end=matches[i+1].start() if i+1<len(matches) else len(source)
    part=source[m.start():end]
    if m.group(1)=='render' and 'mp.observe_property' in part:part=part[:part.index("mp.observe_property")]
    parts[m.group(1)]=part.rstrip()
names='command escape short previous next selection clear_selection delete_selection input_position insert submit initial_query reference_type close bind move_result activate tab install_bindings mouse inside render characters measure_text fit_name wrap_name hover_name'.split()
ui='\n\n'.join(parts[name] for name in names)
ui=ui.replace('subdl','tsdb').replace('SubDL','TSDB')
header=Path('src/header.lua').read_text(encoding='utf-8')
backend=Path('src/backend.lua').read_text(encoding='utf-8')
destination=Path(sys.argv[1]) if len(sys.argv)>1 else Path('tsdb.lua')
destination.parent.mkdir(parents=True,exist_ok=True)
destination.write_text(header+'\n'+ui+'\n'+backend,encoding='utf-8')
print('Built tsdb.lua from src (29 UI methods).')
