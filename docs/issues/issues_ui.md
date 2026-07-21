## Issues

### 1. Not Flat UI

The still doesn't look how I showed in the images it's still the older sidebar which looks like it's on top of the content instead of being flat and integrated into the layout. Please ensure the sidebar is flush with the main content area, with no visible elevation or shadow separating them.

Check image

![](docs/issues/images/{open-new-folder,khadi-open}.png)

### 2. Folder button on top right

The folder button on the top right is kinda moving out the edge. I don't think we need that button at all.

![image](./images/folder-plus-button-top-right.png)

### 3. History GIT

The history in git has a lot of space on the left in each commit, doesn't make sense.

Check the `history-dot-*.png` images in docs/issues/images folder please.


### 4. Terminal Tab

Terminal tab should be like other tab similar in line of a file open in the editor.

Checking `terminal-tab-should-*` image in docs/issues/images folder

### 5. Bracket updates, comments, others

When I select some part and click on open of any type of branckets that selected part should come into that bracket.

When one clicks on `cmd + /` in VS Code it comments that line or that selected part out or if it's already commented it gets uncommented. The comments depend on single and multi line selection as different languages treat single language comments and multi-language comment as different syntax. We need to implement somehting similar. Can we use help from the LSP or tree-sitter?

### 6. `cmd + n` should open a blank untitled document which on `cmd + s` could be saved wherever the user wants.

### 7. `cmd + shift + n` can open a new window and just like how the `cmd + n` does right now.

### 8. Better loading when commit message is getting generated. 

When the commot message is getting generated we can show a better animation of a gradient border (selected theme colors mix) or something around the entire input part (see: docs/issues/images/commit-area.png) and we also give a stop button as well to stop generating which will stop the stream.

### 9. Worktree

The worktree names and branch names are not visible correctly also for worktree we should have a better icon as well. Can we fix that part? I don't think we need that big worktree actions button we can just have 3 dot icon.


see: docs/issues/images/worktree.png

### 10. The branch list is just a normal dropdown and very hard to search based on branch name.

Create a custom searchable dropdown component which is reusable in other places as well as in this branch name part as well and replace the current with that.

### 11. Branch name if git initilized at a better place

Currently, if git is initialized then the current branch is only known if one is in the source control open. We need to show it in a better place in the bottom bar somewhere and from there only one can switch the branch as well.

### 12. In Markdown if we've image path (relative or absolute) in preview we don't see those.

### 13. In Preview mode also one should be able to edit markdown and the live updates should happen.

### 14. Have all the VS Code shortcuts like cmd + b to open the file tree, cmd + G for source control, cmd + shift +f already does find, ctrl g will open the pallete with : at start and when open in file we can go to that line number like :20 or :n cursor moves there. All other shortcuts you can think of.

### 15. The git commit - when and by whom was it commited in a file on a line is not shown - only non commited and only latest lines show those.