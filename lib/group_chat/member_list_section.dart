import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/group_chat/group_chat_model.dart';
import 'package:yoked_in/provider/group_chat_provider.dart';
import 'package:yoked_in/provider/user_status_provider.dart';
import 'package:yoked_in/widgets/user_avatar.dart';
import 'package:yoked_in/widgets/utilis.dart';
import 'package:yoked_in/other_screens/view_user_profile_screen.dart';

class MembersListSection extends ConsumerStatefulWidget {
  final GroupModel group;
  final String currentUserId;
  final bool isAdmin;
  final String groupId;

  const MembersListSection({
    super.key,
    required this.group,
    required this.currentUserId,
    required this.isAdmin,
    required this.groupId,
  });

  @override
  ConsumerState<MembersListSection> createState() => _MembersListSectionState();
}

class _MembersListSectionState extends ConsumerState<MembersListSection> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredMemberIds = widget.group.members.where((id) {
      if (_query.trim().isEmpty) return true;
      final member = ref.watch(memberInfoProvider(id)).asData?.value;
      return member != null && member.name.toLowerCase().contains(_query.trim().toLowerCase());
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: 'Search members by name...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty ? null : IconButton(
                onPressed: () { _searchController.clear(); setState(() => _query = ''); },
                icon: const Icon(Icons.clear),
              ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ),
        if (filteredMemberIds.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_query.isEmpty ? 'No members found.' : 'No members match "$_query".'),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: filteredMemberIds.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 72, endIndent: 16),
            itemBuilder: (context, index) {
              final memberId = filteredMemberIds[index];
              final memberAsync = ref.watch(memberInfoProvider(memberId));
              return memberAsync.when(
                data: (user) {
                  if (user == null) return const SizedBox.shrink();
                  final isMemberAdmin = widget.group.admins.contains(memberId);
                  final isCurrentUser = memberId == widget.currentUserId;
                  void openProfile() => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => ViewUserProfileScreen(userId: memberId)));

                  return Stack(
                    children: [
                      ListTile(
                        leading: GestureDetector(onTap: openProfile, child: UserAvatar(
                          photoUrl: user.photoURL, radius: 22, fallbackIcon: Icons.person)),
                        title: GestureDetector(
                          onTap: openProfile,
                          child: Text('${user.name}${isCurrentUser ? ' (You)' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        subtitle: Text(isMemberAdmin ? 'Admin' : 'Member'),
                        trailing: (widget.isAdmin && !isCurrentUser)
                            ? PopupMenuButton<String>(
                                itemBuilder: (context) => [
                                  if (!isMemberAdmin) const PopupMenuItem(value: 'make_admin', child: Text('Make Admin')),
                                  if (isMemberAdmin && widget.group.admins.length > 1) const PopupMenuItem(value: 'remove_admin', child: Text('Remove Admin')),
                                  const PopupMenuItem(value: 'remove', child: Text('Remove from Group', style: TextStyle(color: Colors.red))),
                                ],
                                onSelected: (value) => _handleMemberAction(context, ref, value, memberId, user.name),
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: 15,
                        left: 48,
                        child: Consumer(builder: (context, ref, _) {
                          final statusAsync = ref.watch(userStatusProvider(user.uid));
                          return statusAsync.when(
                            data: (online) => CircleAvatar(radius: 5, backgroundColor: online ? Colors.green : Colors.grey),
                            loading: () => const CircleAvatar(radius: 5, backgroundColor: Colors.grey),
                            error: (_, __) => const CircleAvatar(radius: 5, backgroundColor: Colors.grey),
                          );
                        }),
                      ),
                    ],
                  );
                },
                loading: () => const ListTile(leading: CircleAvatar(child: Icon(Icons.person)), title: Text('Loading...')),
                error: (_, __) => const SizedBox.shrink(),
              );
            },
          ),
      ],
    );
  }

  Future<void> _handleMemberAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    String memberId,
    String userName,
  ) async {
    final chatService = ref.read(groupChatServiceProvider);

    if (action == 'make_admin') {
      await chatService.makeAdmin(
        groupId: widget.groupId,
        userId: memberId,
        userName: userName,
      );
      // ✅ Add this
      ref.invalidate(groupStreamProvider(widget.groupId));
      if (context.mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.success,
          description: '$userName is now an admin',
        );
      }
    } else if (action == 'remove_admin') {
      await chatService.removeAdmin(
        groupId: widget.groupId,
        userId: memberId,
        userName: userName,
      );
      // ✅ Add this
      ref.invalidate(groupStreamProvider(widget.groupId));

      if (context.mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.success,
          description: '$userName is no longer an admin',
        );
      }
    } else if (action == 'remove') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove Member'),
          content: Text('Remove $userName from group?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirm == true) {
        await chatService.removeGroupMember(
          groupId: widget.groupId,
          userId: memberId,
          userName: userName,
        );
        // ✅ Add this
        ref.invalidate(groupStreamProvider(widget.groupId));
        if (context.mounted) {
          showAppSnackbar(
            context: context,
            type: SnackbarType.success,
            description: '$userName removed from group',
          );
        }
      }
    }
  }
}
