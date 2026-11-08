using Revise
using DataBrowser

supergan_data = "/Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data"
supergan_project = define_project("SuperGaN")
register_csv!(supergan_project; read_options=(comment="#",))
supergan_workspace = open_workspace(supergan_project, supergan_data; cache=false)
supergan_browser = open_browser(supergan_workspace; wait=false)
