/*******************************************************************************************************
 * @classname: PrepareMySandbox
 * @tests: PrepareMySandboxTest
 * Above annotation complies with https://github.com/renatoliveira/apex-test-list
 ******************************************************************************************************/
global class PrepareMySandbox implements SandboxPostCopy {

    @TestVisible
    private static Sandbox_Config__mdt config;

    private static Sandbox_Config__mdt getConfig() {
        if (config == null) {
            List<Sandbox_Config__mdt> records = [
                SELECT Public_Group_Name__c, Admin_Role_Name__c, New_Profile_Name__c, Permission_Set_Name__c
                FROM Sandbox_Config__mdt
                WHERE DeveloperName = 'Template'
                LIMIT 1
            ];
            config = records.isEmpty() ? null : records[0];
        }
        return config;
    }

    global PrepareMySandbox() {}

    global void runApexClass(SandboxContext context) {
        System.debug('Org ID: ' + context.organizationId());
        System.debug('Sandbox ID: ' + context.sandboxId());
        System.debug('Sandbox Name: ' + context.sandboxName());

        if (getConfig() == null) {
            System.debug('PrepareMySandbox: No Sandbox_Config__mdt record found with DeveloperName "Template". Skipping.');
            return;
        }

        try {
            updateProfilesAndResetPasswordsForPublicGroupMembers();
        } catch (Exception ex) {
            System.debug('PrepareMySandbox error: ' + ex.getMessage());
        }
    }

    public void updateProfilesAndResetPasswordsForPublicGroupMembers() {
        Sandbox_Config__mdt cfg = getConfig();

        List<Group> groups = [SELECT Id FROM Group WHERE Name = :cfg.Public_Group_Name__c LIMIT 1];
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = :cfg.New_Profile_Name__c LIMIT 1];
        List<PermissionSet> permSets = [SELECT Id FROM PermissionSet WHERE Name = :cfg.Permission_Set_Name__c LIMIT 1];
        List<UserRole> roles = [SELECT Id FROM UserRole WHERE Name = :cfg.Admin_Role_Name__c LIMIT 1];

        if (groups.isEmpty()) {
            System.debug('PrepareMySandbox: Group "' + cfg.Public_Group_Name__c + '" not found.');
            return;
        }
        if (profiles.isEmpty()) {
            System.debug('PrepareMySandbox: Profile "' + cfg.New_Profile_Name__c + '" not found.');
            return;
        }
        if (permSets.isEmpty()) {
            System.debug('PrepareMySandbox: PermissionSet "' + cfg.Permission_Set_Name__c + '" not found.');
            return;
        }
        if (roles.isEmpty()) {
            System.debug('PrepareMySandbox: Role "' + cfg.Admin_Role_Name__c + '" not found.');
            return;
        }

        List<User> usersToUpdate = getUsersToUpdate(groups[0], profiles[0]);

        if (!usersToUpdate.isEmpty()) {
            update usersToUpdate;
            System.debug('Profile updated for ' + usersToUpdate.size() + ' users.');
            assignPermSet(usersToUpdate, permSets[0]);
            assignRole(usersToUpdate, roles[0]);
            resetPasswords(usersToUpdate);
        } else {
            System.debug('No eligible active users found in the Public Group.');
        }
    }

    private List<User> getUsersToUpdate(Group publicGroup, Profile newProfile) {
        List<User> usersToUpdate = new List<User>();
        Set<Id> userIds = new Set<Id>();
        Id currentUserId = UserInfo.getUserId();

        for (GroupMember member : [SELECT UserOrGroupId FROM GroupMember WHERE GroupId = :publicGroup.Id]) {
            Id userOrGroupId = member.UserOrGroupId;
            if (userOrGroupId != null && userOrGroupId.getSObjectType() == User.SObjectType && userOrGroupId != currentUserId) {
                userIds.add(userOrGroupId);
            }
        }

        for (User user : [SELECT Id, ProfileId, Email, UserRoleId FROM User WHERE Id IN :userIds AND IsActive = true]) {
            user.ProfileId = newProfile.Id;
            if (user.Email != null && user.Email.contains('.invalid')) {
                user.Email = user.Email.replace('.invalid', '');
            }
            usersToUpdate.add(user);
        }

        return usersToUpdate;
    }

    private void assignRole(List<User> users, UserRole adminRole) {
        for (User user : users) {
            user.UserRoleId = adminRole.Id;
        }
        try {
            update users;
            System.debug('Role assigned to ' + users.size() + ' users.');
        } catch (DmlException ex) {
            System.debug('Error assigning role: ' + ex.getMessage());
        }
    }

    private void resetPasswords(List<User> users) {
        for (User u : users) {
            System.resetPassword(u.Id, true);
        }
        System.debug('Passwords reset for ' + users.size() + ' users.');
    }

    private void assignPermSet(List<User> users, PermissionSet permSet) {
        Set<Id> userIds = new Set<Id>();
        for (User u : users) {
            userIds.add(u.Id);
        }

        List<PermissionSetAssignment> existingAssignments = [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE AssigneeId IN :userIds
            AND PermissionSetId = :permSet.Id
        ];
        Set<Id> alreadyAssignedUserIds = new Set<Id>();
        for (PermissionSetAssignment psa : existingAssignments) {
            alreadyAssignedUserIds.add(psa.AssigneeId);
        }

        List<PermissionSetAssignment> psAssignments = new List<PermissionSetAssignment>();
        for (User u : users) {
            if (!alreadyAssignedUserIds.contains(u.Id)) {
                psAssignments.add(new PermissionSetAssignment(
                    AssigneeId = u.Id,
                    PermissionSetId = permSet.Id
                ));
            }
        }

        if (!psAssignments.isEmpty()) {
            try {
                insert psAssignments;
                System.debug('Permission set assigned to ' + psAssignments.size() + ' users.');
            } catch (DmlException ex) {
                System.debug('Error during permission set assignment: ' + ex.getMessage());
            }
        } else {
            System.debug('No new assignments required. All users already have the permission set.');
        }
    }
}
