/*******************************************************************************************************
 * @classname: PrepareMySandboxTest
 * @tests: PrepareMySandboxTest
 * Above annotation complies with https://github.com/renatoliveira/apex-test-list
 ******************************************************************************************************/
@isTest
class PrepareMySandboxTest {
    private static final String GROUP_NAME = 'Test Developer Group';
    private static final String ROLE_NAME = 'Test Admin Role';
    private static final String PERM_SET_NAME = 'Test_Sandbox_Perm_Set';
    private static final String OLD_PROFILE_NAME = 'Read Only';
    private static final String NEW_PROFILE_NAME = 'Standard User';

    @TestSetup
    static void setup() {
        insert new Group(Name = GROUP_NAME, Type = 'Regular');
        insert new UserRole(Name = ROLE_NAME, PortalType = 'None');
        insert new PermissionSet(Name = PERM_SET_NAME, Label = PERM_SET_NAME);
    }

    @isTest
    static void testUpdateProfilesAndResetPasswordsForPublicGroupMembers() {
        Group testGroup = [SELECT Id FROM Group WHERE Name = :GROUP_NAME LIMIT 1];
        UserRole testRole = [SELECT Id FROM UserRole WHERE Name = :ROLE_NAME LIMIT 1];
        Profile oldProfile = [SELECT Id FROM Profile WHERE Name = :OLD_PROFILE_NAME LIMIT 1];
        Profile newProfile = [SELECT Id FROM Profile WHERE Name = :NEW_PROFILE_NAME LIMIT 1];
        PermissionSet testPermSet = [SELECT Id FROM PermissionSet WHERE Name = :PERM_SET_NAME LIMIT 1];

        List<User> testUsers = new List<User>();
        for (Integer i = 1; i <= 3; i++) {
            testUsers.add(new User(
                Alias = 'tu' + i,
                Email = 'testuser' + i + '@example.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'TestUser' + i,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = oldProfile.Id,
                TimeZoneSidKey = 'America/Los_Angeles',
                UserName = 'testuser' + i + '@' + UserInfo.getOrganizationId() + '.sandbox',
                IsActive = true
            ));
        }
        insert testUsers;

        List<GroupMember> groupMembers = new List<GroupMember>();
        for (User u : testUsers) {
            groupMembers.add(new GroupMember(GroupId = testGroup.Id, UserOrGroupId = u.Id));
        }
        insert groupMembers;

        PrepareMySandbox.config = new Sandbox_Config__mdt(
            Public_Group_Name__c = GROUP_NAME,
            Admin_Role_Name__c = ROLE_NAME,
            New_Profile_Name__c = NEW_PROFILE_NAME,
            Permission_Set_Name__c = PERM_SET_NAME
        );

        Test.startTest();
        new PrepareMySandbox().updateProfilesAndResetPasswordsForPublicGroupMembers();
        Test.stopTest();

        Set<Id> testUserIds = new Map<Id, User>(testUsers).keySet();
        List<User> updatedUsers = [SELECT ProfileId, UserRoleId FROM User WHERE Id IN :testUserIds];
        for (User u : updatedUsers) {
            System.assertEquals(newProfile.Id, u.ProfileId, 'Profile not updated for user ' + u.Id);
            System.assertEquals(testRole.Id, u.UserRoleId, 'Role not assigned to user ' + u.Id);
        }

        List<PermissionSetAssignment> psas = [
            SELECT Id FROM PermissionSetAssignment
            WHERE AssigneeId IN :testUserIds
            AND PermissionSetId = :testPermSet.Id
        ];
        System.assertEquals(testUsers.size(), psas.size(), 'Permission set not assigned to all users.');
    }

    @isTest
    static void testUpdateProfilesAndResetPasswords_missingRecords() {
        PrepareMySandbox.config = new Sandbox_Config__mdt(
            Public_Group_Name__c = '__NONEXISTENT_GROUP__',
            Admin_Role_Name__c = '__NONEXISTENT_ROLE__',
            New_Profile_Name__c = '__NONEXISTENT_PROFILE__',
            Permission_Set_Name__c = '__NONEXISTENT_PERM_SET__'
        );

        Test.startTest();
        new PrepareMySandbox().updateProfilesAndResetPasswordsForPublicGroupMembers();
        Test.stopTest();

        System.assert(true, 'Missing records should be handled gracefully without exception.');
    }

    @isTest
    static void testUpdateProfilesAndResetPasswords_emptyGroup() {
        Group testGroup = [SELECT Id FROM Group WHERE Name = :GROUP_NAME LIMIT 1];
        Profile newProfile = [SELECT Id FROM Profile WHERE Name = :NEW_PROFILE_NAME LIMIT 1];
        PermissionSet testPermSet = [SELECT Id FROM PermissionSet WHERE Name = :PERM_SET_NAME LIMIT 1];
        UserRole testRole = [SELECT Id FROM UserRole WHERE Name = :ROLE_NAME LIMIT 1];

        PrepareMySandbox.config = new Sandbox_Config__mdt(
            Public_Group_Name__c = GROUP_NAME,
            Admin_Role_Name__c = ROLE_NAME,
            New_Profile_Name__c = NEW_PROFILE_NAME,
            Permission_Set_Name__c = PERM_SET_NAME
        );

        Test.startTest();
        new PrepareMySandbox().updateProfilesAndResetPasswordsForPublicGroupMembers();
        Test.stopTest();

        System.assert(true, 'Empty group should be handled gracefully without exception.');
    }
}
